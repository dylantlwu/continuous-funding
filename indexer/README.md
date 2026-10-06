# Indexer (Envio HyperIndex)

Indexes Continuous Funding v3 on Monad testnet (chain 10143) from the deployment block:

| Entity | From | Used for |
|---|---|---|
| `Stats` (one row, `global`) | `Opened`, `Closed`, `Liquidated`, `OrderRejected`, `VaultSeeded`, `VaultWithdrawn` | The page's activity strip: wallets, fills, closes, liquidations, volume, fees |
| `Trade` | `Opened`, `Closed`, `Liquidated` | Every fill, close and liquidation with its transaction |
| `MarketPoint` | `MarketUpdated` | The market's own funding record: `p`, `c` and the funding index over time |
| `FeedPost` | `ConsensusFeed.Posted` | Every venue value the relayer reported, so any median can be rechecked |

Realised vault P&L is `vaultCash` on chain minus what was seeded net of withdrawals; the indexer supplies the
second part.

```bash
pnpm install
pnpm test          # intent tests, no network or Docker needed
pnpm dev           # local run: needs Docker and ENVIO_API_TOKEN in .env (see .env.example)
```
