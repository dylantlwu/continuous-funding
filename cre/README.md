# CRE workflow: the relayer as a Chainlink Runtime Environment workflow

`funding-feed/` posts the five venues' predicted BTC funding to a ConsensusFeed, like `validation/relayer.py`, but
every node of a Chainlink DON reads the venues itself and the nodes agree on each value before the DON signs the
report. Chainlink's forwarder delivers it to `src/cre/CreFeedReceiver.sol`, which hands the five values to the feed;
the feed computes the median and enforces its bounds exactly as for the Python relayer.

| File | What |
|---|---|
| `funding-feed/workflow.ts` | Cron trigger → one HTTP read per venue with node consensus (median per field) → report → EVM write |
| `funding-feed/rates.ts` | Endpoints, parsing and the per-second conversion, identical to `validation/recorder.py` and `relayer.py` |
| `funding-feed/config.*.json` | Schedule, chain (`monad-testnet`), receiver address, gas limit, minimum venues (3) |

```bash
cd funding-feed && bun install && bun test          # parsing and conversion tests
cre workflow simulate funding-feed --target staging-settings --broadcast   # from cre/, needs `cre login` and CRE_ETH_PRIVATE_KEY in .env
```

The CRE edition of the feed and its receiver are in `deployments/monad-testnet-cre.json`. Simulation goes through
Chainlink's MockKeystoneForwarder on Monad testnet; a deployed workflow uses the KeystoneForwarder
(`CreFeedReceiver.setForwarder`).
