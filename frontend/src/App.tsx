import { useCallback, useEffect, useRef, useState } from "react";
import type { Address } from "viem";
import { api, pythConf, pythPrice, pythWad, type ChainConfig, type Consensus, type MarketSample, type PythPrint } from "./api";
import { EXPLORER, FAUCET, client, connect, existingAccount, explain, readAll, type Market, type Mine } from "./chain";
import { CadenceChart } from "./components/CadenceChart";
import { PositionCard } from "./components/PositionCard";
import { RateCard } from "./components/RateCard";
import { Ticket } from "./components/Ticket";
import { cStatus, type RatePoint } from "./funding";

const REPO = "https://github.com/dylantlwu/continuous-funding";

export function App() {
  const [cfg, setCfg] = useState<ChainConfig | null>(null);
  const [points, setPoints] = useState<RatePoint[]>([]);
  const [consensus, setConsensus] = useState<Consensus | null>(null);
  const [print, setPrint] = useState<PythPrint | null>(null);
  const [market, setMarket] = useState<Market | null>(null);
  const [mine, setMine] = useState<Mine | null>(null);
  const [samples, setSamples] = useState<MarketSample[]>([]);
  const [account, setAccount] = useState<Address | null>(null);
  const [now, setNow] = useState(Date.now());
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState("");
  const [chainErr, setChainErr] = useState("");
  const fails = useRef(0);
  const printRef = useRef<PythPrint | null>(null);
  printRef.current = print;

  useEffect(() => { api.config().then(setCfg).catch((e) => setErr(explain(e))); }, []);
  useEffect(() => { existingAccount().then((a) => a && setAccount(a)).catch(() => {}); }, []); // no popup on reload

  // off-chain data: rate history (chart), live venues, latest Pyth print
  useEffect(() => {
    const hist = () => api.history(24).then((d) => setPoints(d.points)).catch(() => {});
    const cons = () => api.consensus().then(setConsensus).catch(() => {});
    const px = () => api.latest().then(setPrint).catch(() => {});
    const mkt = () => api.market(24).then((d) => setSamples(d.samples)).catch(() => {});
    hist(); cons(); px(); mkt();
    const ids = [setInterval(hist, 60_000), setInterval(cons, 30_000), setInterval(px, 2_000), setInterval(mkt, 300_000),
                 setInterval(() => setNow(Date.now()), 1000)];
    return () => ids.forEach(clearInterval);
  }, []);

  // on-chain data: one Multicall3 read per new block (at most one in flight)
  const refresh = useCallback(async () => {
    if (!cfg) return;
    const p = printRef.current;
    const r = await readAll(cfg, account ?? undefined, p ? pythWad(p) : undefined);
    setMarket(r.market);
    setMine(r.mine);
  }, [cfg, account]);
  useEffect(() => {
    if (!cfg) return;
    let inFlight = false;
    const tick = () => {
      if (inFlight) return;
      inFlight = true;
      refresh()
        .then(() => { fails.current = 0; setChainErr(""); })
        .catch((e) => { if (++fails.current >= 3) setChainErr(explain(e)); }) // say so, never show stale numbers silently
        .finally(() => { inFlight = false; });
    };
    tick();
    return client.watchBlockNumber({ onBlockNumber: tick, pollingInterval: 700, emitMissed: false });
  }, [cfg, refresh]);

  useEffect(() => { // follow account and network changes in the wallet
    const eth = window.ethereum;
    if (!eth) return;
    const onAcc = (a: string[]) => setAccount((a[0] as Address) ?? null);
    eth.on?.("accountsChanged", onAcc);
    return () => eth.removeListener?.("accountsChanged", onAcc);
  }, []);

  async function onConnect() {
    setErr("");
    try { setAccount(await connect()); } catch (e) { setErr(explain(e)); }
  }

  const price = print ? pythPrice(print) : null;
  const conf = print ? pythConf(print) : null;
  const short = (a: string) => `${a.slice(0, 6)}…${a.slice(-4)}`;
  const cBadge = market && cStatus(Number(market.lastPostTime), Math.floor(now / 1000), Number(market.rate[0]),
                                   consensus?.median_per_second_wad ?? null);

  return (
    <div className="page">
      <header className="top reveal d1">
        <div className="mark">
          <span className="word">Continuous Funding</span>
          <span className="tag">BTC-PERP · Monad testnet</span>
        </div>
        <div className="live">
          <span style={{ whiteSpace: "nowrap" }} title="c on chain: its age, and its gap to the live five-venue median. While positions are open the keeper posts when the gap reaches 0.25% a year, or hourly.">
            <span className={`dot ${cBadge?.due ? "stale" : ""}`} />{cBadge ? cBadge.text : "connecting…"}
          </span>
          <span>BTC {price ? `$${price.toLocaleString("en-US", { maximumFractionDigits: 2 })}` : "—"}</span>
          <span>block {market ? market.block.toLocaleString("en-US") : "—"}</span>
        </div>
        {account ? (
          <span className="mono" style={{ fontSize: 13 }}>
            {short(account)} · {mine ? (Number(mine.mon) / 1e18).toFixed(3) : "…"} MON
          </span>
        ) : (
          <button className="btn" onClick={onConnect}>Connect wallet</button>
        )}
      </header>
      {err && <div className="msg err" style={{ marginTop: 12 }}>{err}</div>}
      {chainErr && <div className="msg err" style={{ marginTop: 12 }}>Cannot read the chain right now; the numbers below may be stale. {chainErr}</div>}

      <section className="hero">
        <div className="reveal d2">
          <h1>Funding that <em>never waits</em> for the hour.</h1>
          <p className="lede">
            A BTC perpetual on Monad whose funding accrues every second, re-evaluated in every block that touches it,
            and anchored to five venues so the vault that takes the other side is protected.
          </p>
          <ul className="facts">
            <li><span className="n">01</span><span><b>rate = c + p.</b> c is the median of Binance, OKX, Bybit, Hyperliquid and Bitget; p moves with this market's own long/short imbalance, within ±5% a year.</span></li>
            <li><span className="n">02</span><span><b>No price is chosen by anyone.</b> You commit; the order fills at the first Pyth print 2 seconds later.</span></li>
            <li><span className="n">03</span><span><b>A healthy position cannot be liquidated.</b> Health is checked in the trader's favour; bad data reverts.</span></li>
          </ul>
        </div>
        <section className="card reveal d3">
          <div className="card-h">
            <h2>Same rate, three clocks</h2>
            <span className="sub">cumulative funding paid by a $10,000 long</span>
          </div>
          <CadenceChart points={points} now={now} />
        </section>
      </section>

      <div className="row">
        <RateCard market={market} consensus={consensus} price={price} samples={samples} />
        <Ticket cfg={cfg} account={account} mine={mine} price={price} conf={conf} onConnect={onConnect} busy={busy} setBusy={setBusy} />
        <PositionCard cfg={cfg} account={account} mine={mine} price={price} block={market?.block ?? null} busy={busy} setBusy={setBusy} />
      </div>

      <section className="how reveal d5">
        <div>
          <div className="t">t</div>
          <h3>You commit</h3>
          <p>Size and margin go on chain with no price. Nobody, including you, knows the fill price yet.</p>
        </div>
        <div>
          <div className="t">t + 2 s</div>
          <h3>Pyth publishes</h3>
          <p>The first BTC print at or after t + 2 s is the only one the contract accepts; Pyth's own contract proves it is the first.</p>
        </div>
        <div>
          <div className="t">≈ t + 5 s</div>
          <h3>The keeper settles</h3>
          <p>One wallet confirmation per trade: the keeper fills the order at that print a moment later. Anyone can, at the same price. Fast blocks are what make this feel instant.</p>
        </div>
      </section>

      <footer className="foot">
        <div>
          <h4>Read before you trade</h4>
          <ul>
            <li>Testnet only. Test USDC has no value. Not audited.</li>
            {cfg && (() => {
              const maxLev = Math.round(1e18 / Number(cfg.initialMarginRate)), mmr = Number(cfg.maintenanceMarginRate) / 1e16;
              return <li>Up to {maxLev}x, isolated margin. A {maxLev}x position is liquidated after a move of about {100 / maxLev - mmr}% against it (maintenance margin {mmr}%).</li>;
            })()}
            <li>c is posted on-chain while positions are open whenever the live median moves 0.25% a year from it, or at least hourly, and before an open if it is over 70 minutes old; between posts it stays at its last value and open positions accrue at it. A post never re-prices the past.</li>
            <li>One relayer key reports the five venue rates; the contract takes the median and limits c to ±100% a year, moving at most 5% a year per minute. Every reported value is public in the feed's events.</li>
            <li>Opens are refused when the vault could not survive a 25% move against the larger side. If the vault cannot pay a winning close, the close reverts rather than paying less.</li>
            <li>Need gas? <a href={FAUCET} target="_blank" rel="noreferrer">Monad testnet faucet</a>.</li>
          </ul>
        </div>
        <div>
          <h4>Contracts · source verified on Sourcify</h4>
          {cfg ? (
            <ul>
              <li>PerpEngine <a className="addr" href={`${EXPLORER}/address/${cfg.engine}`} target="_blank" rel="noreferrer">{short(cfg.engine)}</a></li>
              <li>ConsensusFeed <a className="addr" href={`${EXPLORER}/address/${cfg.feed}`} target="_blank" rel="noreferrer">{short(cfg.feed)}</a></li>
              <li>PythPriceSource <a className="addr" href={`${EXPLORER}/address/${cfg.priceSource}`} target="_blank" rel="noreferrer">{short(cfg.priceSource)}</a></li>
              <li>TestUSDC <a className="addr" href={`${EXPLORER}/address/${cfg.usdc}`} target="_blank" rel="noreferrer">{short(cfg.usdc)}</a></li>
            </ul>
          ) : <p className="muted">loading…</p>}
          <p style={{ marginTop: 12 }}><a href={REPO} target="_blank" rel="noreferrer">Source and design notes</a></p>
        </div>
      </footer>
    </div>
  );
}
