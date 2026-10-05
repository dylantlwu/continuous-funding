// The two-step trade as the user lives it. Commit (no price) -> wait for the first Pyth print at or after
// commit + settleDelay -> settle with that print (the user's own wallet; the keeper does it after ~10 s if they
// don't). The price is fixed by time, so neither the trader nor the settler chooses it.
import { decodeErrorResult, decodeEventLog, maxUint256, parseUnits, type Address, type TransactionReceipt } from "viem";
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

/** Settle our own order with the pinned print; if the user declines, wait for the keeper. */
async function fill(cfg: ChainConfig, account: Address, progress: Progress): Promise<TransactionReceipt | null> {
  const { commitTime } = await readOrder(cfg, account);
  const at = commitTime + cfg.settleDelay;
  progress("wait", `Waiting for the first Pyth print at or after ${new Date(at * 1000).toISOString().slice(11, 19)} UTC…`);
  let print = null;
  for (let i = 0; i < 40 && !print; i++) {
    print = await api.at(at).catch(() => null);
    if (!print) await sleep(700);
  }
  if (!print) throw new Error("Pyth has no print for the fill time yet; the keeper will fill the order.");
  progress("fill", `Fill price fixed by the print at ${new Date(print.publish_time * 1000).toISOString().slice(11, 19)} UTC. Confirm to settle.`);
  try {
    const fee = await oracleFee(cfg, print.update);
    return await write(account, cfg.engine, abis.perpEngineAbi, "settle", [account, [print.update]], fee);
  } catch (e) {
    const { commitTime: still } = await readOrder(cfg, account);
    if (still === 0) return null; // someone settled it meanwhile
    progress("keeper", `${explain(e)} The keeper fills it at the same price within about 10 seconds.`);
    for (let i = 0; i < 90; i++) {
      if ((await readOrder(cfg, account)).commitTime === 0) return null;
      await sleep(1000);
    }
    throw new Error("The order was not filled in time; it can be cancelled and its margin returned.");
  }
}

/** What happened at settlement, from the receipt's own events: filled (with the fill price), closed (with the
 * cash returned), or, for opens, rejected with the contract's reason and the margin refunded. */
export function outcomeFromReceipt(r: Pick<TransactionReceipt, "logs" | "transactionHash"> | null): Outcome | null {
  if (!r) return null;
  const usd = (x: bigint, dp: bigint) =>
    (Number(x) / Number(10n ** dp)).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  for (const log of r.logs) {
    try {
      const ev = decodeEventLog({ abi: abis.perpEngineAbi, data: log.data, topics: log.topics });
      if (ev.eventName === "OrderRejected") {
        const why = decodeErrorResult({ abi: abis.perpEngineAbi, data: ev.args.reason });
        return { ok: false, text: `Rejected at the fill price (${why.errorName}); your margin was refunded.`, tx: r.transactionHash };
      }
      if (ev.eventName === "Opened") {
        return { ok: true, text: `Filled at $${usd(ev.args.price, 18n)}.`, tx: r.transactionHash };
      }
      if (ev.eventName === "Closed") {
        return { ok: true, text: `Closed at $${usd(ev.args.price, 18n)}; $${usd(ev.args.payout, 6n)} returned to your wallet.`, tx: r.transactionHash };
      }
    } catch { /* another contract's event */ }
  }
  return { ok: false, text: "Settled, but no fill event was found; check the transaction.", tx: r.transactionHash };
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
  progress("commit", "Commit the order in your wallet. No price is chosen yet.");
  await write(account, cfg.engine, abis.perpEngineAbi, "commitOpen", [size, margin]);
  const r = await fill(cfg, account, progress);
  progress("done");
  const pos = await client.readContract({ ...engine(cfg), functionName: "positions", args: [account] });
  return outcomeFromReceipt(r) ?? (pos[0] !== 0n ? { ok: true, text: "Filled by the keeper." } : { ok: false, text: "Rejected at the fill price; your margin was refunded." });
}

export async function closePosition(cfg: ChainConfig, account: Address, progress: Progress): Promise<Outcome> {
  progress("commit", "Commit the close in your wallet. Closing is never blocked.");
  await write(account, cfg.engine, abis.perpEngineAbi, "commitClose", []);
  const r = await fill(cfg, account, progress);
  progress("done");
  return outcomeFromReceipt(r) ?? { ok: true, text: "Closed by the keeper." };
}

export async function faucet(cfg: ChainConfig, account: Address) {
  await write(account, cfg.usdc, abis.testUsdcAbi, "mint", [account, 10_000_000_000n]);
}
