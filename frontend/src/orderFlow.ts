// The two-step trade as the user lives it: one wallet confirmation (owner, 2026-10-05). Commit (no price) ->
// the keeper settles at the first Pyth print at or after commit + settleDelay as soon as it exists. If the
// keeper has not settled 15 s after the fill time, the user settles it themselves at the same pinned print.
// The price is fixed by time, so neither the trader nor the settler chooses it.
import { decodeErrorResult, decodeEventLog, maxUint256, parseUnits, type Address, type Hex, type Log } from "viem";
import { api, type ChainConfig } from "./api";
import { abis, client, explain, oracleFee, write } from "./chain";

export type Step = "wake" | "approve" | "commit" | "wait" | "fill" | "keeper" | "done";
export type Progress = (step: Step, note?: string) => void;
export type Outcome = { ok: boolean; text: string; tx?: string };

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const engine = (cfg: ChainConfig) => ({ address: cfg.engine, abi: abis.perpEngineAbi }) as const;

async function readOrder(cfg: ChainConfig, account: Address) {
  const o = await client.readContract({ ...engine(cfg), functionName: "orders", args: [account] });
  return { commitTime: Number(o[2]), isClose: o[3] };
}

/** Before an open: make sure the on-chain consensus is fresh (the relayer posts only when asked). */
async function ensureFreshFeed(cfg: ChainConfig, progress: Progress) {
  const f = { address: cfg.feed, abi: abis.consensusFeedAbi } as const;
  const [stale, last, block] = await Promise.all([
    client.readContract({ ...f, functionName: "isStale", args: [0] }),
    client.readContract({ ...f, functionName: "lastPostTime", args: [0] }),
    client.getBlock(),
  ]);
  if (!stale && Number(block.timestamp) - Number(last) < 180) return;
  progress("wake", "Posting the five venues' rates on-chain (the relayer pays)…");
  await api.wake().catch((e) => { if (e.status !== 429) throw e; }); // 429: someone just asked; the post is coming
  for (let i = 0; i < 30; i++) {
    if (!(await client.readContract({ ...f, functionName: "isStale", args: [0] }))) return;
    await sleep(1000);
  }
  throw new Error("The consensus rate could not be refreshed. Try again in a minute.");
}

/** Wait for the keeper to settle; if it has not 15 s after the fill time, settle with the pinned print ourselves.
 * Returns the outcome read from the settlement's own events. */
async function fill(cfg: ChainConfig, account: Address, commitBlock: bigint, progress: Progress): Promise<Outcome> {
  const { commitTime } = await readOrder(cfg, account);
  const at = commitTime + cfg.settleDelay;
  const hhmmss = (t: number) => new Date(t * 1000).toISOString().slice(11, 19);
  progress("wait", `Filling at the first Pyth print at or after ${hhmmss(at)} UTC. The keeper settles it; no second confirmation.`);
  while (Date.now() / 1000 < at + 15) {
    if ((await readOrder(cfg, account)).commitTime === 0) return outcomeFromChain(cfg, account, commitBlock);
    await sleep(1000);
  }
  progress("fill", "The keeper has not filled it yet. Confirm in your wallet to settle it yourself at the same price.");
  const print = await api.at(at);
  try {
    const fee = await oracleFee(cfg, print.update);
    const r = await write(account, cfg.engine, abis.perpEngineAbi, "settle", [account, [print.update]], fee);
    return outcomeFromLogs(r.logs, account, r.transactionHash) ?? noEvent(r.transactionHash);
  } catch (e) {
    if ((await readOrder(cfg, account)).commitTime === 0) return outcomeFromChain(cfg, account, commitBlock);
    progress("keeper", `${explain(e)} Waiting for the keeper…`);
    for (let i = 0; i < 60; i++) {
      if ((await readOrder(cfg, account)).commitTime === 0) return outcomeFromChain(cfg, account, commitBlock);
      await sleep(1000);
    }
    throw new Error("The order was not filled in time; after 60 s it can be cancelled and its margin returned.");
  }
}

/** Find this account's settlement events since the commit (the keeper sent the transaction). */
async function outcomeFromChain(cfg: ChainConfig, account: Address, fromBlock: bigint): Promise<Outcome> {
  const logs = await client.getLogs({ address: cfg.engine, fromBlock, toBlock: "latest" });
  return outcomeFromLogs(logs, account) ?? noEvent();
}

const noEvent = (tx?: Hex): Outcome => ({ ok: false, text: "Settled, but no fill event was found; check the transaction.", tx });

/** What happened at settlement, from its own events: filled (fill price), closed (cash returned), or, for
 * opens, rejected with the contract's reason, the fee kept (margin shortfall only) and the refund. */
export function outcomeFromLogs(
  logs: readonly Pick<Log, "data" | "topics" | "transactionHash">[],
  account: Address,
  tx?: Hex,
): Outcome | null {
  const usd = (x: bigint, dp: bigint) =>
    (Number(x) / Number(10n ** dp)).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  for (const log of logs) {
    try {
      const ev = decodeEventLog({ abi: abis.perpEngineAbi, data: log.data, topics: log.topics as [Hex, ...Hex[]] });
      const who = (ev.args as { account?: Address }).account;
      if (!who || who.toLowerCase() !== account.toLowerCase()) continue;
      const hash = tx ?? log.transactionHash ?? undefined;
      if (ev.eventName === "OrderRejected") {
        const why = decodeErrorResult({ abi: abis.perpEngineAbi, data: ev.args.reason }).errorName;
        const kept = ev.args.feeKept;
        return {
          ok: false,
          tx: hash,
          text: kept > 0n
            ? `Rejected at the fill price (${why}): the $${usd(kept, 6n)} open fee was kept and the rest of your margin refunded.`
            : `Rejected at the fill price (${why}); your margin was refunded in full.`,
        };
      }
      if (ev.eventName === "Opened") return { ok: true, tx: hash, text: `Filled at $${usd(ev.args.price, 18n)}.` };
      if (ev.eventName === "Closed") {
        return { ok: true, tx: hash, text: `Closed at $${usd(ev.args.price, 18n)}; $${usd(ev.args.payout, 6n)} returned to your wallet.` };
      }
    } catch { /* another event or contract */ }
  }
  return null;
}

export async function openPosition(cfg: ChainConfig, account: Address, sizeBtc: number, marginUsd: number, progress: Progress): Promise<Outcome> {
  const size = parseUnits(sizeBtc.toFixed(6), 18);
  const margin = parseUnits(marginUsd.toFixed(2), 6);
  await ensureFreshFeed(cfg, progress);
  const allowance = await client.readContract({ address: cfg.usdc, abi: abis.testUsdcAbi, functionName: "allowance", args: [account, cfg.engine] });
  if (allowance < margin) {
    progress("approve", "One-time approval for the engine to take test USDC as margin.");
    await write(account, cfg.usdc, abis.testUsdcAbi, "approve", [cfg.engine, maxUint256]);
  }
  progress("commit", "Confirm the order in your wallet. No price is chosen yet.");
  const c = await write(account, cfg.engine, abis.perpEngineAbi, "commitOpen", [size, margin]);
  const out = await fill(cfg, account, c.blockNumber, progress);
  progress("done");
  return out;
}

export async function closePosition(cfg: ChainConfig, account: Address, progress: Progress): Promise<Outcome> {
  progress("commit", "Commit the close in your wallet. Closing is never blocked.");
  const c = await write(account, cfg.engine, abis.perpEngineAbi, "commitClose", []);
  const out = await fill(cfg, account, c.blockNumber, progress);
  progress("done");
  return out;
}

export async function faucet(cfg: ChainConfig, account: Address) {
  await write(account, cfg.usdc, abis.testUsdcAbi, "mint", [account, 10_000_000_000n]);
}
