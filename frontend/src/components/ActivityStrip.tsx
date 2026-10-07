import { useEffect, useState } from "react";
import { usd } from "../funding";

// The Envio HyperIndex deployment of indexer/ (public GraphQL). Totals come from the indexer; vault cash comes from
// the chain read the page already does, so the vault's P&L shown is vault cash minus what was seeded net of withdrawals.
export const ENVIO_GRAPHQL = "https://indexer.dev.hyperindex.xyz/246512b/v1/graphql";

export type Stats = {
  traders: number; fills: number; closes: number; liquidations: number; rejections: number;
  volumeUsd: string; feesUsdc: string; vaultSeeded: string; vaultWithdrawn: string;
};

export async function fetchStats(url = ENVIO_GRAPHQL): Promise<Stats | null> {
  const r = await fetch(url, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ query: "{ Stats(where:{id:{_eq:\"global\"}}) { traders fills closes liquidations rejections volumeUsd feesUsdc vaultSeeded vaultWithdrawn } }" }),
  });
  const body = await r.json();
  if (!r.ok || body.errors) throw new Error(body.errors?.[0]?.message ?? `HTTP ${r.status}`);
  return body.data.Stats[0] ?? null;
}

/** Realised vault P&L in USDC: vault cash on chain (6 decimals) minus seeded net of withdrawals (indexer, 6 decimals). */
export const vaultPnl = (vaultCash: bigint, s: Stats) => Number(vaultCash - (BigInt(s.vaultSeeded) - BigInt(s.vaultWithdrawn))) / 1e6;

export function ActivityStrip({ vaultCash }: { vaultCash: bigint | null }) {
  const [s, setS] = useState<Stats | null>(null);
  const [err, setErr] = useState("");
  useEffect(() => {
    const load = () => fetchStats().then((x) => { setS(x); setErr(""); }).catch((e) => setErr(String(e.message ?? e)));
    load();
    const id = setInterval(load, 30_000);
    return () => clearInterval(id);
  }, []);

  const cells: [string, string][] = s ? [
    ["wallets that traded", String(s.traders)],
    ["fills", String(s.fills)],
    ["closes", String(s.closes)],
    ["liquidations", String(s.liquidations)],
    ["volume", usd(Number(BigInt(s.volumeUsd) / 10n ** 12n) / 1e6, 0)],
    ["fees to the vault", usd(Number(s.feesUsdc) / 1e6)],
    ["vault P&L", vaultCash != null ? usd(vaultPnl(vaultCash, s)) : "—"],
  ] : [];

  return (
    <section className="activity reveal d5" aria-label="Testnet activity, indexed by Envio">
      <div className="activity-h">
        <span className="eyebrow">testnet activity since v3 · indexed by <a href="https://envio.dev" target="_blank" rel="noreferrer">Envio</a></span>
        {err && <span className="muted" style={{ fontSize: 12 }}>indexer unreachable: {err}</span>}
      </div>
      <div className="activity-cells">
        {(s ? cells : [["", "loading…"]]).map(([k, v]) => (
          <div key={k || "loading"}><div className="v mono">{v}</div><div className="k">{k}</div></div>
        ))}
      </div>
    </section>
  );
}
