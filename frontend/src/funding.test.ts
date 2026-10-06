import { describe, expect, it } from "vitest";
import { approxLiquidationPrice, aprPct, cadences, cStatus, marginFor, nextSettlement, sparkRange, type RatePoint } from "./funding";

const H = 3_600_000;
const tenPctPerSecond = (0.1 / (365 * 24 * 3600)) * 1e18; // 10% APR as a per-second rate, 1e18

// A constant 10% APR for 10 hours, one point per minute, starting at 00:00 UTC.
const flat: RatePoint[] = Array.from({ length: 10 * 60 + 1 }, (_, i) => [i * 60_000, tenPctPerSecond]);

describe("cadences: the chart's story", () => {
  // Without this, the hero chart could show the venues' steps paying a different amount from the smooth line,
  // which would be a false claim: settlement cadence moves WHEN funding is paid, not how much.
  it("step lines meet the smooth line at every settlement time", () => {
    const pts = cadences(flat, 10_000);
    for (const p of pts.filter((q) => q.t % H === 0 && q.t > 0)) {
      expect(p.hourly).toBeCloseTo(p.smooth, 9);
    }
    const at8 = pts.find((p) => p.t === 8 * H)!;
    expect(at8.eightHour).toBeCloseTo(at8.smooth, 9);
  });

  // Without this, a step line could start paying before its first settlement, hiding the lag the chart exists
  // to show (a trader leaving at 7:59 skips the whole 8-hour payment).
  it("between settlements the steps stay flat and lag the smooth line", () => {
    const pts = cadences(flat, 10_000);
    const p = pts.find((q) => q.t === 7 * H + 59 * 60_000)!;
    expect(p.eightHour).toBe(0);
    expect(p.hourly).toBeCloseTo(pts.find((q) => q.t === 7 * H)!.smooth, 9);
    expect(p.smooth).toBeGreaterThan(p.hourly);
  });

  // Without this, a units slip (hours vs seconds, a missing 1e18) would put the wrong dollars on the chart:
  // 10% APR on $10,000 for one hour is 10,000 x 0.1 / 8,760 = $0.114155.
  it("accrues the right dollars", () => {
    const one = cadences(flat, 10_000).find((p) => p.t === H)!;
    expect(one.smooth).toBeCloseTo((10_000 * 0.1) / 8760, 6);
    expect(aprPct(tenPctPerSecond)).toBeCloseTo(10, 9);
  });

  // Without this, the live "now" end of the smooth line would freeze between minute points.
  it("extends the smooth line to the present second", () => {
    const pts = cadences(flat, 10_000, 10 * H + 30_000);
    const last = pts[pts.length - 1];
    expect(last.t).toBe(10 * H + 30_000);
    expect(last.smooth - pts[pts.length - 2].smooth).toBeCloseTo((10_000 * 0.1 * 30) / (365 * 24 * 3600), 9);
  });

  it("settlement clocks are aligned to 00:00 UTC", () => {
    expect(nextSettlement(5 * H + 1, 8)).toBe(8 * H);
    expect(nextSettlement(5 * H + 1, 1)).toBe(6 * H);
  });
});

describe("pre-trade estimates", () => {
  // Without this, the margin sent with a commit could miss the initial requirement after a small move in the
  // 2 seconds before the fill, and every such order would be rejected and refunded.
  it("margin covers 10x initial margin and the fee after a 1% adverse move", () => {
    const m = marginFor(0.1, 100_000, 10);
    expect(m).toBeGreaterThanOrEqual((0.1 * 101_000) / 10 + 0.1 * 101_000 * 0.0005);
  });

  // Without this, the "≈" liquidation price could use a different formula from the contract's
  // liquidationPrice view (same algebra: equity = maintenance rate x notional, the rate read from the contract).
  it("liquidation estimate solves equity = maintenance", () => {
    for (const mmr of [0.02, 0.05]) {
      const p = approxLiquidationPrice(1, 100_000, 4_000, mmr);
      expect(4_000 + (p - 100_000)).toBeCloseTo(mmr * p, 6);
      const s = approxLiquidationPrice(-1, 100_000, 4_000, mmr);
      expect(4_000 - (s - 100_000)).toBeCloseTo(mmr * s, 6);
    }
  });
});

describe("c status badge", () => {
  const wad = (apr: number) => (apr / 100) * 1e18 / (365 * 24 * 3600);
  // Without this, an hour-old c (normal under the move-or-hourly policy) would read as a fault, or a c that has
  // drifted past the posting threshold would read as fine: the badge must judge c by its gap, not its age.
  it("judges c by its gap to the live median, not by its age", () => {
    const old = cStatus(1_000, 1_000 + 3_000, wad(4), wad(4.1));
    expect(old.text).toBe("c 50 min old · 0.10% off median");
    expect(old.due).toBe(false);
    expect(cStatus(1_000, 1_030, wad(4), wad(4.3)).due).toBe(true);
  });
});

describe("p sparkline range", () => {
  // Without this, a p moving 0.025% a year per hour (0.5 BTC of skew) is drawn inside a fixed ±5% band and looks
  // like a flat line: the chart would say "p does not move" when it does.
  it("fits a small move so it fills most of the chart", () => {
    const [lo, hi] = sparkRange([0, -0.004, -0.012], 5);
    expect(hi - lo).toBeLessThan(0.02);
    expect(0.012 / (hi - lo)).toBeGreaterThan(0.8);
  });
  // Without this, an all-negative p would be drawn without its zero line and could be read as positive.
  it("always shows zero, and never more than the band", () => {
    expect(sparkRange([-0.5, -0.4], 5)[1]).toBeGreaterThan(0);
    expect(sparkRange([4.99, 5], 5)).toEqual([-0.5, 5]);
  });
  // Without this, an empty book (p exactly 0 for hours) would divide by a zero range.
  it("gives a flat series a non-zero range", () => {
    const [lo, hi] = sparkRange([0, 0, 0], 5);
    expect(hi - lo).toBeGreaterThan(0);
  });
});
