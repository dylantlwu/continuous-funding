// The backend (validation/service.py), served from the same origin. It holds the Pyth API key; the browser
// only ever sees signed price updates.
import type { Address, Hex } from "viem";
import type { RatePoint } from "./funding";

export type ChainConfig = {
  chainId: number;
  engine: Address;
  feed: Address;
  priceSource: Address;
  usdc: Address;
  feedId: Hex;
  settleDelay: number;
  orderTtl: number;
  relayer: Address;
};

export type PythPrint = { price: number; conf: number; expo: number; publish_time: number; update: Hex };

export type Consensus = {
  venues: Record<string, { rate_per_interval?: number; interval_h?: number; missing?: string }>;
  rates_per_second_wad: (number | null)[];
  median_per_second_wad: number | null;
};

async function call<T>(path: string, init?: RequestInit): Promise<T> {
  const r = await fetch(path, init);
  const body = await r.json().catch(() => ({}));
  if (!r.ok) throw Object.assign(new Error(body.error ?? `HTTP ${r.status}`), { status: r.status });
  return body as T;
}

export const api = {
  config: () => call<ChainConfig>("/api/chain/config"),
  consensus: () => call<Consensus>("/api/consensus"),
  history: (hours = 24) => call<{ points: RatePoint[] }>(`/api/consensus/history?hours=${hours}`),
  latest: () => call<PythPrint>("/api/pyth/latest"),
  /** The first Pyth print at or after unix second `t`: the only price an order committed at t - 2 can fill at. */
  at: (t: number) => call<PythPrint>(`/api/pyth/at?t=${t}`),
  /** Ask the relayer to post the venue rates on-chain if the feed is older than 3 minutes. */
  wake: () => call<{ posted: boolean }>("/api/wake", { method: "POST" }),
};

export const pythPrice = (p: PythPrint) => p.price * 10 ** p.expo;
export const pythConf = (p: PythPrint) => p.conf * 10 ** p.expo;
/** Price scaled 1e18, as the contract stores it. */
export const pythWad = (p: PythPrint): bigint =>
  18 + p.expo >= 0 ? BigInt(p.price) * 10n ** BigInt(18 + p.expo) : BigInt(p.price) / 10n ** BigInt(-(18 + p.expo));
