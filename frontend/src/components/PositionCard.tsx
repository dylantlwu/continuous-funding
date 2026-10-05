import { useEffect, useRef, useState } from "react";
import type { Address } from "viem";
import type { ChainConfig } from "../api";
import { EXPLORER, explain, type Mine } from "../chain";
import { usd } from "../funding";
import { closePosition, type Outcome, type Step } from "../orderFlow";

/** Every number here that involves money comes from the contract (positions, positionValue, liquidationPrice),
 * read every block; nothing is recomputed in the browser. */
export function PositionCard({ cfg, account, mine, price, block, busy, setBusy }: {
  cfg: ChainConfig | null; account: Address | null; mine: Mine | null; price: number | null; block: bigint | null;
  busy: boolean; setBusy: (b: boolean) => void;
}) {
  const [step, setStep] = useState<Step | null>(null);
  const [note, setNote] = useState("");
  const [result, setResult] = useState<Outcome | null>(null);
  const [err, setErr] = useState("");
  const owedRef = useRef<HTMLDivElement>(null);
  const prevOwed = useRef<bigint | null>(null);

  const size = mine ? Number(mine.position[0]) / 1e18 : 0;
  const deposit = mine ? Number(mine.position[1]) / 1e6 : 0;
  const entry = mine ? Number(mine.position[3]) / 1e18 : 0;
  const pnl = mine?.value ? Number(mine.value[0]) / 1e18 : 0;
  const owed = mine?.value ? Number(mine.value[1]) / 1e18 : 0;
  const equity = deposit + pnl - owed;
  const liq = mine ? Number(mine.liquidationPrice) / 1e18 : 0;
  const pending = mine && mine.order[2] !== 0n;

  useEffect(() => { // flash the funding figure whenever a new block changes it
    const v = mine?.value?.[1] ?? null;
    if (v !== null && prevOwed.current !== null && v !== prevOwed.current && owedRef.current) {
      owedRef.current.classList.remove("flash");
      void owedRef.current.offsetWidth;
      owedRef.current.classList.add("flash");
    }
    prevOwed.current = v;
  }, [mine]);

  async function close() {
    if (!cfg || !account) return;
    setBusy(true); setErr(""); setResult(null);
    try { setResult(await closePosition(cfg, account, (s, n) => { setStep(s); setNote(n ?? ""); })); }
    catch (e) { setErr(explain(e)); }
    finally { setBusy(false); setStep(null); }
  }

  return (
    <section className="card reveal d5">
      <div className="card-h">
        <h2>Your position</h2>
        <span className="sub mono">{block ? `block ${block.toLocaleString("en-US")}` : ""}</span>
      </div>
      <div className="card-b">
        {!account ? (
          <div className="empty">Connect a wallet to see your position.</div>
        ) : size === 0 ? (
          <div className="empty">{pending ? "Your order is waiting for its fill price…" : "No position. Open one and watch its funding accrue every block."}</div>
        ) : (
          <>
            <div className="eyebrow">funding owed since entry, updated every block</div>
            <div ref={owedRef} className={`owed ${owed > 0 ? "" : "long"}`}>{usd(owed, 6)}</div>
            <div className="muted" style={{ fontSize: 12.5, marginTop: 4 }}>
              {owed >= 0 ? "you pay this to the vault when you close" : "the vault pays you this when you close"}
            </div>
            <dl className="kv">
              <dt>side · size</dt><dd className={size > 0 ? "long" : "short"}>{size > 0 ? "long" : "short"} {Math.abs(size)} BTC</dd>
              <dt>entry (fill price)</dt><dd>{usd(entry)}</dd>
              <dt>mark (latest Pyth)</dt><dd>{price ? usd(price) : "—"}</dd>
              <dt>unrealised PnL</dt><dd className={pnl >= 0 ? "long" : "short"}>{usd(pnl)}</dd>
              <dt>margin deposited</dt><dd>{usd(deposit)}</dd>
              <dt>equity</dt><dd>{usd(equity)}</dd>
              <dt>liquidation price</dt><dd className="signal">{liq ? usd(liq, 0) : "none"}</dd>
              <dt>distance to liquidation</dt><dd>{liq && price ? `${((Math.abs(price - liq) / price) * 100).toFixed(2)}%` : "—"}</dd>
            </dl>
            <button className="btn ghost" style={{ width: "100%", marginTop: 16 }} onClick={close} disabled={busy || !!pending}>
              {pending ? "Close waiting to fill…" : "Close position"}
            </button>
          </>
        )}
        {step && note && <div className="msg">{note}</div>}
        {err && <div className="msg err">{err}</div>}
        {result && (
          <div className={`msg ${result.ok ? "ok" : "err"}`}>
            {result.text}{" "}
            {result.tx && <a href={`${EXPLORER}/tx/${result.tx}`} target="_blank" rel="noreferrer">View transaction</a>}
          </div>
        )}
      </div>
    </section>
  );
}
