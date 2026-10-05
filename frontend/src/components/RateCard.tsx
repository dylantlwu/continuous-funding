import type { Consensus } from "../api";
import type { Market } from "../chain";
import { aprPct, pct, perHourUsd, usd } from "../funding";

const VENUE_NAMES: Record<string, string> = { binance: "Binance", okx: "OKX", bybit: "Bybit", hyperliquid: "Hyperliquid", bitget: "Bitget" };
const W_APR = 5; // |p| <= 5% APR (docs/design.md, owner decision 2026-10-01)

/** rate = c + p. c and p as the contract sees them right now; the five venues live, off-chain. */
export function RateCard({ market, consensus, price }: { market: Market | null; consensus: Consensus | null; price: number | null }) {
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
          <dt>median now (posted before the next open)</dt>
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
