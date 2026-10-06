// Continuous Funding's relayer as a Chainlink CRE workflow: on a schedule, every node of the DON reads the five
// venues' predicted BTC funding itself, the nodes agree on each value (median per field), and the DON-signed report
// is delivered through Chainlink's forwarder to CreFeedReceiver, which posts it to a ConsensusFeed. The feed then
// computes the median of the five and enforces its bounds exactly as it does for the Python relayer.
import {
	bytesToHex,
	ConsensusAggregationByFields,
	type CronPayload,
	cre,
	getNetwork,
	type HTTPSendRequester,
	median,
	prepareReportRequest,
	type Runtime,
	TxStatus,
} from '@chainlink/cre-sdk'
import { type Address, encodeAbiParameters } from 'viem'
import { z } from 'zod'
import { MISSING, parse, perSecondWad, type Reading, REQUESTS, VENUES } from './rates'

export const configSchema = z.object({
	schedule: z.string(),
	chainSelectorName: z.string(), // "monad-testnet"
	receiverAddress: z.string(), // CreFeedReceiver
	gasLimit: z.string(),
	minVenues: z.number().int().min(3),
})
type Config = z.infer<typeof configSchema>

const fetchVenue = (venue: (typeof VENUES)[number]) => (requester: HTTPSendRequester): Reading => {
	const r = REQUESTS[venue]
	const res = requester
		.sendRequest({
			url: r.url,
			method: r.method,
			body: r.body ? Buffer.from(r.body).toString('base64') : undefined,
			headers: r.body ? { 'Content-Type': 'application/json' } : undefined,
		})
		.result()
	if (res.statusCode !== 200) throw new Error(`${venue} HTTP ${res.statusCode}`)
	const reading = parse[venue](JSON.parse(Buffer.from(res.body).toString('utf-8')))
	if (!Number.isFinite(reading.rate) || !(reading.intervalH > 0)) throw new Error(`${venue} returned no usable rate`)
	return reading
}

/** Five per-second rates in the feed's order; a venue the nodes could not agree on is MISSING, as with the relayer. */
const readVenues = (runtime: Runtime<Config>): bigint[] => {
	const http = new cre.capabilities.HTTPClient()
	return VENUES.map((venue) => {
		try {
			const agreed = http
				.sendRequest(runtime, fetchVenue(venue), ConsensusAggregationByFields<Reading>({ rate: median, intervalH: median }))()
				.result()
			const wad = perSecondWad(agreed.rate, agreed.intervalH)
			runtime.log(`${venue}: ${agreed.rate} per ${agreed.intervalH} h -> ${wad} per second (1e18)`)
			return wad
		} catch (e) {
			runtime.log(`${venue}: missing (${(e as Error).message})`)
			return MISSING
		}
	})
}

export const onCronTrigger = (runtime: Runtime<Config>, payload: CronPayload): string => {
	if (!payload.scheduledExecutionTime) throw new Error('scheduled execution time is required')
	const cfg = runtime.config
	const rates = readVenues(runtime)
	const present = rates.filter((r) => r !== MISSING).length
	if (present < cfg.minVenues) throw new Error(`only ${present} venues, need ${cfg.minVenues}: not posting`)

	// The feed refuses observations from the future: stamp the run's scheduled time, a moment before the block.
	const observedAt = BigInt(payload.scheduledExecutionTime.seconds) - 2n
	const report = runtime
		.report(prepareReportRequest(encodeAbiParameters([{ type: 'uint64' }, { type: 'int256[5]' }], [observedAt, rates as unknown as readonly [bigint, bigint, bigint, bigint, bigint]])))
		.result()

	const network = getNetwork({ chainFamily: 'evm', chainSelectorName: cfg.chainSelectorName, isTestnet: true })
	if (!network) throw new Error(`unknown chain ${cfg.chainSelectorName}`)
	const evm = new cre.capabilities.EVMClient(network.chainSelector.selector)
	const res = evm.writeReport(runtime, { receiver: cfg.receiverAddress as Address, report, gasConfig: { gasLimit: cfg.gasLimit } }).result()

	const tx = bytesToHex(res.txHash || new Uint8Array(32))
	if (res.txStatus !== TxStatus.SUCCESS) throw new Error(`write failed: ${res.errorMessage || res.txStatus} (${tx})`)
	if (res.receiverContractExecutionStatus !== undefined && res.receiverContractExecutionStatus !== 0) {
		throw new Error(`the receiver reverted (status ${res.receiverContractExecutionStatus}): the feed refused the post (${tx})`)
	}
	runtime.log(`posted ${present} venues observed at ${observedAt} in ${tx}`)
	return tx
}

export function initWorkflow(config: Config) {
	return [cre.handler(new cre.capabilities.CronCapability().trigger({ schedule: config.schedule }), onCronTrigger)]
}
