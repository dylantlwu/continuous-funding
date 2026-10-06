// Pure helpers shared by the workflow and its tests. They mirror validation/relayer.py exactly, so the CRE path and the
// Python relayer turn the same venue reading into the same on-chain value.

export const MISSING = -(2n ** 255n) // ConsensusFeed.MISSING = type(int256).min
export const VENUES = ['binance', 'okx', 'bybit', 'hyperliquid', 'bitget'] as const // the feed's order

/** A rate per funding interval -> a per-second fraction scaled 1e18 (relayer.py per_second_wad: round(rate / (h*3600) * 1e18)). */
export const perSecondWad = (rate: number, intervalH: number): bigint => BigInt(Math.round((rate / (intervalH * 3600)) * 1e18))

export type Reading = { rate: number; intervalH: number }

/** Parse each venue's current predicted BTC funding from its public endpoint (same fields as validation/recorder.py). */
export const parse: Record<(typeof VENUES)[number], (body: any) => Reading> = {
	binance: (b) => ({ rate: Number(b.lastFundingRate), intervalH: 8 }), // BTCUSDT is on the default 8 h interval
	okx: (b) => {
		const x = b.data[0]
		const h = (Number(x.nextFundingTime) - Number(x.fundingTime)) / 3.6e6
		return { rate: Number(x.fundingRate), intervalH: h > 0 ? h : 8 }
	},
	bybit: (b) => {
		const x = b.result.list[0]
		return { rate: Number(x.fundingRate), intervalH: Number(x.fundingIntervalHour || 8) }
	},
	hyperliquid: (b) => {
		const views = (b as [string, [string, any][]][]).find(([coin]) => coin === 'BTC')![1]
		const v = Object.fromEntries(views).HlPerp
		return { rate: Number(v.fundingRate), intervalH: Number(v.fundingIntervalHours) }
	},
	bitget: (b) => {
		const x = b.data[0]
		return { rate: Number(x.fundingRate), intervalH: Number(x.fundingRateInterval) }
	},
}

export const REQUESTS: Record<(typeof VENUES)[number], { url: string; method: 'GET' | 'POST'; body?: string }> = {
	binance: { url: 'https://fapi.binance.com/fapi/v1/premiumIndex?symbol=BTCUSDT', method: 'GET' },
	okx: { url: 'https://www.okx.com/api/v5/public/funding-rate?instId=BTC-USDT-SWAP', method: 'GET' },
	bybit: { url: 'https://api.bybit.com/v5/market/tickers?category=linear&symbol=BTCUSDT', method: 'GET' },
	hyperliquid: { url: 'https://api.hyperliquid.xyz/info', method: 'POST', body: '{"type":"predictedFundings"}' },
	bitget: { url: 'https://api.bitget.com/api/v2/mix/market/current-fund-rate?symbol=BTCUSDT&productType=USDT-FUTURES', method: 'GET' },
}
