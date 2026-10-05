import { useState } from "react";
import type { Address } from "viem";
import type { ChainConfig } from "../api";
import { EXPLORER, explain, type Mine } from "../chain";
import { approxLiquidationPrice, marginFor, usd } from "../funding";
import { faucet, openPosition, type Outcome, type Step } from "../orderFlow";

const STEPS: { key: Step; label: string }[] = [
  { key: "wake", label: "Refresh c on-chain, only if it is older than 3 minutes" },
  { key: "commit", label: "Commit size and margin. No price yet" },
  { key: "wait", label: "Wait for the first Pyth print 2 s after the commit" },
  { key: "fill", label: "Settle at that print. Anyone can; the keeper does after 10 s" },
];

export function Ticket({ cfg, account, mine, price, conf, onConnect, busy, setBusy }: {
  cfg: ChainConfig | null; account: Address | null; mine: Mine | null; price: number | null; conf: number | null;
  onConnect: () => void; busy: boolean; setBusy: (b: boolean) => void;
}) {
  const [side, setSide] = useState<"long" | "short">("long");
  const [size, setSize] = useState("0.05");
  const [lev, setLev] = useState(5);
  const [step, setStep] = useState<Step | null>(null);
  const [note, setNote] = useState<string>("");
  const [result, setResult] = useState<Outcome | null>(null);
  const [err, setErr] = useState<string>("");

  const sizeBtc = Number(size) || 0;
  const signed = side === "long" ? sizeBtc : -sizeBtc;
  const entry = price && conf != null ? (side === "long" ? price + conf : price - conf) : null;
  const margin = entry ? marginFor(sizeBtc, entry, lev) : 0;
  const fee = entry ? sizeBtc * entry * 0.0005 : 0;
  const liq = entry ? approxLiquidationPrice(signed, entry, margin - fee) : 0;
  const hasPosition = !!mine && mine.position[0] !== 0n;
  const hasOrder = !!mine && mine.order[2] !== 0n;
  const usdcBal = mine ? Number(mine.usdc) / 1e6 : 0;
  const tooSmall = sizeBtc < 0.001;

  async function go() {
    if (!cfg || !account) return;
    setBusy(true); setErr(""); setResult(null); setStep(null);
    try {
      const out = await openPosition(cfg, account, signed, margin, (s, n) => { setStep(s); setNote(n ?? ""); });
      setResult(out);
    } catch (e) {
      setErr(explain(e));
    } finally {
      setBusy(false); setStep(null);
    }
  }

  async function getUsdc() {
    if (!cfg || !account) return;
    setBusy(true); setErr("");
    try { await faucet(cfg, account); } catch (e) { setErr(explain(e)); } finally { setBusy(false); }
  }

  const idx = step ? STEPS.findIndex((s) => s.key === (step === "approve" ? "commit" : step === "keeper" ? "fill" : step)) : -1;

  return (
    <section className="card reveal d4">
      <div className="card-h">
        <h2>Open a position</h2>
        <span className="sub">BTC-PERP · isolated · test USDC</span>
      </div>
      <div className="card-b">
        <div className="seg">
          <button className={side === "long" ? "on long" : ""} onClick={() => setSide("long")} disabled={busy}>Long</button>
          <button className={side === "short" ? "on short" : ""} onClick={() => setSide("short")} disabled={busy}>Short</button>
        </div>
        <div className="field">
          <label><span>Size</span><span className="mono">min 0.001 BTC</span></label>
          <input className="mono" inputMode="decimal" value={size} onChange={(e) => setSize(e.target.value)} disabled={busy} aria-label="Size in BTC" />
        </div>
        <div className="field">
          <label><span>Leverage</span><span className="mono">{lev}x</span></label>
          <div className="levs">
            {[1, 2, 5, 10].map((l) => (
              <button key={l} className={lev === l ? "on" : ""} onClick={() => setLev(l)} disabled={busy}>{l}x</button>
            ))}
          </div>
        </div>
        <dl className="kv">
          <dt>margin sent (incl. 1% move buffer, fee)</dt><dd>{entry ? usd(margin) : "—"}</dd>
          <dt>open fee 5 bp</dt><dd>{entry ? usd(fee) : "—"}</dd>
          <dt>≈ fill price (price {side === "long" ? "+" : "−"} confidence)</dt><dd>{entry ? usd(entry) : "—"}</dd>
          <dt>≈ liquidation price</dt><dd>{liq ? usd(liq, 0) : "—"}</dd>
          <dt>your test USDC</dt><dd>{account ? usd(usdcBal) : "—"}</dd>
        </dl>

        {!account ? (
          <button className="btn signal" style={{ width: "100%", marginTop: 16 }} onClick={onConnect}>Connect wallet</button>
        ) : usdcBal < margin ? (
          <button className="btn" style={{ width: "100%", marginTop: 16 }} onClick={getUsdc} disabled={busy}>Get 10,000 test USDC</button>
        ) : (
          <button className={`btn ${side}`} style={{ width: "100%", marginTop: 16 }} onClick={go}
                  disabled={busy || hasPosition || hasOrder || tooSmall || !entry}>
            {hasPosition ? "Close your position first" : hasOrder ? "An order is waiting to fill" : `Commit ${side} ${sizeBtc || ""} BTC`}
          </button>
        )}

        <ol className="steps">
          {STEPS.map((s, i) => (
            <li key={s.key} className={i === idx ? "active" : i < idx ? "done" : ""}>
              <span className="i">{i + 1}</span><span>{s.label}</span>
            </li>
          ))}
        </ol>
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
