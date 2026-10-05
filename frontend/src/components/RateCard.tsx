import type { Consensus, MarketSample } from "../api";
import type { Market } from "../chain";
import { aprPct, pct, perHourUsd, sparkRange, usd } from "../funding";

const VENUE_NAMES: Record<string, string> = { binance: "Binance", okx: "OKX", bybit: "Bybit", hyperliquid: "Hyperliquid", bitget: "Bitget" };
const W_APR = 5; // |p| <= 5% APR (docs/design.md, owner decision 2026-10-01)

/** p over the sampled window, on an axis fitted to the samples (always including 0, never beyond the ±5% band),
 * so a slow p is visible. Samples come from the keeper's free reads every 5 min. */
function PHistory({ samples }: { samples: MarketSample[] }) {
  if (samples.length < 2) {
    return <div className="muted" style={{ fontSize: 12.5, marginTop: 8 }}>p history: collecting samples every 5 minutes…</div>;
  }
  const w = 320, h = 54, pad = 4;
  const t0 = samples[0].ts, t1 = samples[samples.length - 1].ts;
  const ps = samples.map((s) => aprPct(Number(s.p)));
  const [lo, hi] = sparkRange(ps, W_APR);
  const x = (t: number) => pad + ((t - t0) / Math.max(1, t1 - t0)) * (w - 2 * pad);
  const y = (apr: number) => pad + ((hi - apr) / (hi - lo)) * (h - 2 * pad);
  const d = samples.map((s, i) => `${i ? "L" : "M"}${x(s.ts).toFixed(1)},${y(ps[i]).toFixed(1)}`).join("");
  const last = ps[ps.length - 1];
  const dp = hi - lo < 0.01 ? 4 : hi - lo < 0.1 ? 3 : 2;
  const span = t1 - t0 < 3600 ? `${Math.round((t1 - t0) / 60)} min` : `${((t1 - t0) / 3600).toFixed(1)} h`;
  // Labels in a gutter, at 0 and at the extreme values actually sampled (not the padded edges of the axis).
  const ticks = [0];
  for (const v of [Math.max(...ps), Math.min(...ps)]) if (ticks.every((t) => Math.abs(y(v) - y(t)) > 10)) ticks.push(v);
  return (
    <div style={{ marginTop: 10 }}>
      <div className="spark">
        <div className="spark-y">
          {ticks.map((v) => <span key={v} style={{ top: `${(y(v) / h) * 100}%` }}>{pct(v, dp)}</span>)}
        </div>
        <svg viewBox={`0 0 ${w} ${h}`} width="100%" height={h} preserveAspectRatio="none" role="img"
             aria-label={`p over the last ${span}, between ${pct(Math.min(...ps), dp)} and ${pct(Math.max(...ps), dp)} a year`}>
          <line x1={pad} x2={w - pad} y1={y(0)} y2={y(0)} stroke="var(--rule)" vectorEffect="non-scaling-stroke" />
          {[W_APR, -W_APR].filter((b) => b >= lo && b <= hi).map((b) => (
            <line key={b} x1={pad} x2={w - pad} y1={y(b)} y2={y(b)} stroke="var(--rule)" strokeDasharray="2 3" vectorEffect="non-scaling-stroke" />
          ))}
          <path d={d} fill="none" stroke="var(--signal)" strokeWidth={1.8} vectorEffect="non-scaling-stroke" />
        </svg>
      </div>
      <div className="band-l" title="p read on chain every 5 minutes by the keeper; the axis is fitted to these samples, with 0 always shown">
        <span>p · {span} · fitted axis</span><span>last {pct(last, dp)}</span>
      </div>
    </div>
  );
}

/** rate = c + p. c and p as the contract sees them right now; the five venues live, off-chain. */
export function RateCard({ market, consensus, price, samples }: {
  market: Market | null; consensus: Consensus | null; price: number | null; samples: MarketSample[];
}) {
  const [c, p, total] = market ? market.rate.map((x) => Number(x)) : [0, 0, 0];
  const pApr = aprPct(p);
  const needle = 50 + Math.max(-1, Math.min(1, pApr / W_APR)) * 50;
  const skewBtc = market ? Number(market.longOI - market.shortOI) / 1e18 : 0;
  return (
    <section className="card reveal d3">
      <div className="card-h">
        <h2>Funding rate now</h2>
        <span className="sub">rate = c + p</span>
      </div>
      <div className="card-b">
        <div className="eyebrow">longs pay, per year</div>
        <div className={`big ${total >= 0 ? "" : "long"}`}>{market ? pct(aprPct(total), 3) : "—"}</div>
        <div className="muted" style={{ fontSize: 13, marginTop: 6 }}>
          a $10,000 long pays <span className="mono">{usd(perHourUsd(total, 10_000), 4)}</span> per hour, accrued every second
        </div>

        <dl className="kv">
          <dt>c · consensus of five venues, on chain</dt>
          <dd>{market ? pct(aprPct(c), 3) : "—"}</dd>
          <dt>p · this market's own imbalance</dt>
          <dd>{market ? pct(pApr, 3) : "—"}</dd>
        </dl>
        <div className="band" aria-label={`p is ${pApr.toFixed(3)}% APR within a ±5% band`}>
          <div className="track" />
          <div className="zero" />
          <div className="needle" style={{ left: `calc(${needle}% - 1px)` }} />
        </div>
        <div className="band-l"><span>−5% shorts pay</span><span>skew {skewBtc >= 0 ? "+" : ""}{skewBtc.toFixed(3)} BTC</span><span>+5% longs pay</span></div>
        <PHistory samples={samples} />

        <div className="eyebrow" style={{ marginTop: 18 }}>live predicted funding, off-chain</div>
        <div className="venues">
          {Object.entries(VENUE_NAMES).map(([k, name], i) => {
            const v = consensus?.rates_per_second_wad[i];
            return (
              <div key={k} className={`venue ${v == null ? "missing" : ""}`} title={consensus?.venues[k]?.missing ?? ""}>
                <div className="n">{name}</div>
                <div className="v">{v == null ? "—" : pct(aprPct(v), 2)}</div>
              </div>
            );
          })}
        </div>
        <dl className="kv">
          <dt>median now (posted when it moves 0.25% from c, or hourly)</dt>
          <dd>{consensus?.median_per_second_wad != null ? pct(aprPct(consensus.median_per_second_wad), 3) : "—"}</dd>
          <dt>vault cash</dt>
          <dd>{market ? usd(Number(market.vaultCash) / 1e6, 0) : "—"}</dd>
          <dt>open interest long / short</dt>
          <dd>{market ? `${(Number(market.longOI) / 1e18).toFixed(3)} / ${(Number(market.shortOI) / 1e18).toFixed(3)} BTC` : "—"}</dd>
          <dt>≈ capacity per side (25% stress)</dt>
          <dd>{market && price ? `${(Number(market.vaultCash) / 1e6 / (price * 0.25)).toFixed(1)} BTC` : "—"}</dd>
        </dl>
      </div>
    </section>
  );
}
