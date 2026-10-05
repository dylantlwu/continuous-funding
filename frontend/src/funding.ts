// Pure funding arithmetic for display. Anything that decides money (fills, PnL, funding owed, liquidation
// price) is read from the contract; this file only draws the chart and pre-trade estimates labelled "≈".

export const YEAR_S = 365 * 24 * 3600;

/** Per-second rate scaled 1e18 -> percent per year. */
export function aprPct(perSecondWad: number | bigint): number {
  return (Number(perSecondWad) * YEAR_S) / 1e16;
}

/** Dollars per hour paid by a long of `notional` USD at a per-second rate (1e18). */
export function perHourUsd(perSecondWad: number, notional: number): number {
  return (perSecondWad / 1e18) * 3600 * notional;
}

export type RatePoint = [tMs: number, perSecondWad: number | null];
export type CadencePoint = { t: number; smooth: number; hourly: number; eightHour: number };

/** Start of the settlement period containing `tMs`, for periods of `hours` aligned to 00:00 UTC. */
export function periodStart(tMs: number, hours: number): number {
  const p = hours * 3_600_000;
  return Math.floor(tMs / p) * p;
}

export function nextSettlement(nowMs: number, hours: number): number {
  return periodStart(nowMs, hours) + hours * 3_600_000;
}

/**
 * Cumulative funding paid by a long of `notional` USD along one rate path, under three settlement cadences:
 * accrued continuously (what this protocol does), settled hourly, settled every 8 hours. The step lines equal
 * the smooth line at each settlement time and stay flat in between: same money, paid later in lumps.
 * Missing minutes (no median) accrue nothing. `nowMs` extends the smooth line to the present second.
 */
export function cadences(points: RatePoint[], notional: number, nowMs?: number): CadencePoint[] {
  if (points.length === 0) return [];
  const out: CadencePoint[] = [];
  let acc = 0;
  const atBoundary = new Map<number, number>(); // settlement time -> cumulative at that time
  let lastRate = 0;
  for (let i = 0; i < points.length; i++) {
    const [t, r] = points[i];
    if (i > 0) {
      const [t0, r0] = points[i - 1];
      acc += ((r0 ?? 0) / 1e18) * ((t - t0) / 1000) * notional;
    }
    lastRate = r ?? 0;
    if (t % 3_600_000 === 0) atBoundary.set(t, acc);
    out.push({ t, smooth: acc, hourly: 0, eightHour: 0 });
  }
  if (nowMs !== undefined && nowMs > points[points.length - 1][0]) {
    const tl = points[points.length - 1][0];
    out.push({ t: nowMs, smooth: acc + (lastRate / 1e18) * ((nowMs - tl) / 1000) * notional, hourly: 0, eightHour: 0 });
  }
  const first = points[0][0];
  const stepAt = (t: number, hours: number) => {
    const b = periodStart(t, hours);
    return b <= first ? 0 : atBoundary.get(b) ?? 0;
  };
  for (const p of out) {
    p.hourly = stepAt(p.t, 1);
    p.eightHour = stepAt(p.t, 8);
  }
  return out;
}

/** Margin to send with a commit: initial margin at `leverage` on a price allowed to move `moveBuffer` before the
 * fill, plus the open fee, rounded up to whole cents. A margin that is too thin is refunded at settlement. */
export function marginFor(sizeBtc: number, price: number, leverage: number, feeRate = 0.0005, moveBuffer = 0.01): number {
  const notional = sizeBtc * price * (1 + moveBuffer);
  return Math.ceil((notional / leverage + notional * feeRate) * 100) / 100;
}

/** ≈ liquidation price for a new position, the contract's formula with no funding yet:
 * P = (size·entry − deposit) / (size − mmr·|size|). The exact value is read from the contract after the fill. */
export function approxLiquidationPrice(sizeBtc: number, entry: number, deposit: number, mmr = 0.05): number {
  const den = sizeBtc - mmr * Math.abs(sizeBtc);
  const p = (sizeBtc * entry - deposit) / den;
  return p > 0 ? p : 0;
}

export function usd(x: number, dp = 2): string {
  const s = Math.abs(x).toLocaleString("en-US", { minimumFractionDigits: dp, maximumFractionDigits: dp });
  return (x < 0 ? "−$" : "$") + s;
}

export function pct(x: number, dp = 2): string {
  return (x < 0 ? "−" : x > 0 ? "+" : "") + Math.abs(x).toFixed(dp) + "%";
}

export function countdown(ms: number): string {
  const s = Math.max(0, Math.floor(ms / 1000));
  const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), sec = s % 60;
  const two = (n: number) => String(n).padStart(2, "0");
  return h > 0 ? `${h}:${two(m)}:${two(sec)}` : `${two(m)}:${two(sec)}`;
}

/** The keeper posts c once the venues' median is this far from it (or hourly) while positions are open. */
export const POST_MOVE_APR = 0.25;

/** Header status of c: how old the on-chain value is and how far it sits from the live median. An hour-old c is
 * normal under the posting policy; what matters is the gap, so the badge shows the gap, not "fresh" or "stale". */
export function cStatus(lastPostS: number, nowS: number, cWad: number, medianWad: number | null) {
  if (!lastPostS) return { text: "c not posted yet", due: true };
  const s = Math.max(0, nowS - lastPostS);
  const age = s < 90 ? `${s} s` : s < 5400 ? `${Math.round(s / 60)} min` : `${(s / 3600).toFixed(1)} h`;
  if (medianWad == null) return { text: `c posted ${age} ago`, due: false };
  const gap = Math.abs(aprPct(medianWad) - aprPct(cWad));
  return { text: `c posted ${age} ago · ${gap.toFixed(2)}% from live median`, due: gap >= POST_MOVE_APR };
}
