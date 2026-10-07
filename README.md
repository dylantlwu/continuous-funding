# Continuous Funding

An oracle-priced BTC perpetual on Monad whose funding protects the vault that takes the other side of
traders: **rate = c + p**, where `c` is the median of five venues' live predicted funding and `p` is a
premium driven by this market's own long/short imbalance, bounded to ±5% a year. Funding is re-evaluated
in every block that touches the market and accrued per second. Orders fill at the first Pyth price published
2 seconds after they are committed, so no one, trader or settler, chooses the price.

**Live on Monad testnet:** https://continuous-funding.up.railway.app
**Demo video (2:44):** https://youtu.be/KaSGbcB9P0s · with [Chainlink CRE](https://youtu.be/u-WPm42MuAA) (1:09) ·
[Envio](https://youtu.be/ULtT4qeI4CQ) (43 s) · [Alchemy](https://youtu.be/zehgDFu1fRs) (51 s)
Monad Metropolis · Track 01 Onchain Finance & Trading · testnet only · not audited

- [What it is](#what-it-is) · [Try it](#try-it) · [Why Monad](#why-monad) · [Architecture](#architecture)
- [Correctness](#correctness) · [Run it yourself](#run-it-yourself) · [Trust model and limits](#trust-model-and-known-limits)
- [Prior art](#prior-art) · [Prior work](#prior-work) · [AI disclosure](#ai-disclosure) · [Attribution](#attribution)

The full design, with every decision and its reason: [docs/design.md](docs/design.md).

## What it is

A vault-backed perpetual (the vault takes the other side of every trade, as on GMX, Gains or LeverUp) carries
the inventory the crowd leaves it. Funding is one of the few levers it has on that inventory, and the usual
choices pull in different directions:

- **Pay the market rate (`rate = c`).** The rate looks like everyone else's, but the vault holds whatever the
  crowd does, for as long as it does.
- **Charge only for your own imbalance** (Synthetix SIP-279 velocity, GMX V2 adaptive funding, LeverUp). This
  starts from a level unrelated to where the hedge lives, so hedgers initially take the wrong side.

This project anchors to the market and adds a bounded, memoryful premium:

| Term | What it is | How it moves |
|---|---|---|
| `c` | Median of Binance, OKX, Bybit, Hyperliquid and Bitget predicted funding, normalised to per second. The median is computed on chain from the five reported values. | Limited to ±100% a year and to 5% a year per minute of change, measured over time: one post after a quiet spell catches up as far as the elapsed time allows. Posted whenever the median moves 0.25% a year from it, or at least hourly, and before an open if it is old. |
| `p` | This market's own imbalance premium. | `dp/dt = 2% a year per hour × clamp(skew / 40 BTC, ±1)`, bounded to ±5% a year. It keeps moving while the imbalance lasts. |

While one side dominates, `p` makes that side pay more and the other side earn more. That pays hedgers to
take the vault's inventory off it, and it does so by the market's standard, not an arbitrary one. Funding
does **not** stop fast, toxic flow (5% a year is about 1.4 bp a day); a vault capacity rule, trading fees and
two-step fills do that.

**What the contracts make impossible** (each backed by tests, see [Correctness](#correctness)):

- **Mixing up margins.** Deposited margin (`MarginStatic`) and required margin (`MarginDynamic`) are distinct
  types, so mixing them by accident fails to compile.
- **Liquidating a healthy position.** The health check rounds toward "healthy" and uses the price ± confidence
  in the trader's favour. A position whose equity equals its maintenance margin to the wei is not liquidated.
- **Choosing the price.** An order fills only at the Pyth print that Pyth's own contract proves is the first
  at or after commit + 2 s.
- **Letting touch frequency change what is owed.** One clock in seconds, with closed-form integrals.
- **Overselling the vault.** Every open must leave the vault solvent after a 25% move against the larger side,
  net of profit it already owes; at most 10 BTC per account.
- **A free option on the fill.** Committing just enough margin and being refunded whenever the print moves
  against you: a margin-shortfall rejection keeps the open fee. A commit needs a fresh feed but the fill does
  not, so a fill cannot be refused by waiting for the feed to go stale, and a fill that runs out of gas reverts
  the settlement instead of refunding.

## Try it

1. Open https://continuous-funding.up.railway.app with MetaMask (or any injected EVM wallet). The page
   adds or switches to Monad Testnet (chain 10143).
2. Get a little testnet MON for gas at https://faucet.monad.xyz.
3. Click **Get 10,000 test USDC**. Test USDC is free and worthless.
4. Choose long or short, a size (0.001 to 10 BTC) and leverage (up to 25x), then confirm once in your wallet (your
   first trade also asks you to approve test USDC, once). If
   the on-chain `c` is about to go stale (over 70 minutes old), the backend posts it first. The keeper fills the
   order at the first Pyth print 2 seconds after your commit; there is no second confirmation.
5. Watch the funding owed on your position change every block, then close it the same way.

**Contracts on Monad testnet** (sources verified, exact match, on [MonadVision](https://testnet.monadvision.com)'s
Sourcify and on [sourcify.dev](https://sourcify.dev)):

| Contract | Address |
|---|---|
| PerpEngine | [`0x1a13dbC366aB86CABdfAD3739A7BB607041B442a`](https://testnet.monadvision.com/address/0x1a13dbC366aB86CABdfAD3739A7BB607041B442a) |
| ConsensusFeed | [`0x4210FC24D1e0114AE3B3977301dDcbBbA252eF85`](https://testnet.monadvision.com/address/0x4210FC24D1e0114AE3B3977301dDcbBbA252eF85) |
| PythPriceSource | [`0x27fD7bEb9836c7FCe9C4E7CFF8CbF33e887A8236`](https://testnet.monadvision.com/address/0x27fD7bEb9836c7FCe9C4E7CFF8CbF33e887A8236) |
| TestUSDC | [`0x65DaBeFE62B7B43e861920699A6B158496946e09`](https://testnet.monadvision.com/address/0x65DaBeFE62B7B43e861920699A6B158496946e09) |
| ConsensusFeed (CRE edition) | [`0xBF155844e2c79066130e2802c34B274598884526`](https://testnet.monadvision.com/address/0xBF155844e2c79066130e2802c34B274598884526) |
| CreFeedReceiver | [`0xB297B253Ebe15d1D4b15aA56e54a52bEDd1b3c20`](https://testnet.monadvision.com/address/0xB297B253Ebe15d1D4b15aA56e54a52bEDd1b3c20) |

Deployment record: [deployments/monad-testnet.json](deployments/monad-testnet.json) (v3). Earlier versions stay on
chain: [v1](deployments/monad-testnet-v1.json) and [v2](deployments/monad-testnet-v2.json), each replaced after an
independent review (v2: `c` could fall behind the venues; v3: the feed's stale window contradicted its posting
policy, and leverage up to 25x).

## Why Monad

- **Two-step fills that feel instant.** Trades are two-step, which is standard (Synthetix v3 does it): commit,
  then fill at a later oracle price nobody chose. On Monad a commit is included in about a second and the keeper
  fills it a few seconds later, with one wallet confirmation. With 2-second blocks the same flow takes several blocks; with
  12-second blocks it is unusable for active trading.
- **Liquidations on a 3-second price.** Liquidations and pokes must use a Pyth price at most 3 seconds old, and
  never older than the last price used. The keeper's latency probe on its host measures each RPC call and the
  Pyth fetch, and estimates the path from fetching the price to sending the transaction (one fetch plus about
  seven calls, before inclusion): with Alchemy's Monad endpoint, 0.01 s per call and about 0.4 s (2026-10-06);
  on the public RPC it was 0.21 s per call and about 1.6 s.
- **Funding re-evaluated in every block that touches the market.** Several Monad blocks share one second, so funding is accrued per second
  and `p` moves on the same clock.
- **Built for how Monad charges gas.** Monad charges the gas **limit** and reprices cold state access, so every
  write sets its limit from the node's own estimate (plus 15% from the browser, 5% for the relayer's
  fixed-cost post). Monad's public RPC serves 100 blocks per `eth_getLogs` and Alchemy's 1,000, so the keeper keeps a cursor in
  storage and never rescans.
- **Pyth's first-print proof works on Monad testnet.** Checked with `eth_call` against the Monad testnet Pyth
  contract before relying on it: the first print after a time is accepted and a later one is refused.

## Architecture

```
 Browser (React + viem)                         Backend on Railway (validation/service.py)
 ─────────────────────                          ──────────────────────────────────────────
 reads: one Multicall3 call per block,          recorder   five venues' predicted funding, every minute (SQLite)
        all figures read at one block number    relayer    posts the five rates to ConsensusFeed
 writes: commitOpen / commitClose / settle      keeper     settles orders, liquidates (simulates first, never pays for a revert)
         from the user's wallet                 API        /api/pyth/* (holds the Pyth key), /api/consensus, /api/wake
            │                                              │
            └──────────────── Monad testnet (chain 10143) ─┘
   PerpEngine ── reads c ──> ConsensusFeed        PerpEngine ── prices ──> PythPriceSource ──> Pyth
   (vault cash, positions,   (median on chain,    (latest price for bots;   (parsePriceFeedUpdatesUnique
    two-step orders,          clamped, integral)    first print after t       for the first print)
    funding index)                                  for orders)
```

| Part | Where | What it does |
|---|---|---|
| `PerpEngine` | [src/PerpEngine.sol](src/PerpEngine.sol) | Vault, isolated positions, two-step orders, funding index, liquidation |
| `Funding` | [src/lib/Funding.sol](src/lib/Funding.sol) | Closed-form integral of the bounded premium `p` |
| `Units`, `Margin` | [src/lib/Units.sol](src/lib/Units.sol) | Value types (`Usdc`, `UsdWad`, `MarginStatic`, `MarginDynamic`) and the only two places margins meet |
| `ConsensusFeed` | [src/ConsensusFeed.sol](src/ConsensusFeed.sol) | Takes five venue rates, computes the median, clamps it, keeps its time integral |
| `IFundingFeed` | [src/interfaces/IFundingFeed.sol](src/interfaces/IFundingFeed.sol) | The feed's read side, for other markets that anchor to `c` ([docs/feed.md](docs/feed.md)) |
| Indexer | [indexer/](indexer/) | [Envio](https://envio.dev) HyperIndex: activity totals, every trade, the market's funding record and every feed post. Deployed on Envio's hosted service; the page's activity strip reads its [public GraphQL endpoint](https://indexer.dev.hyperindex.xyz/246512b/v1/graphql) |
| CRE workflow | [cre/](cre/), [src/cre/CreFeedReceiver.sol](src/cre/CreFeedReceiver.sol) | The relayer as a [Chainlink CRE](https://docs.chain.link/cre) workflow: every node of a DON reads the five venues, the nodes agree on each value, and the signed report reaches a ConsensusFeed through Chainlink's forwarder |
| `PythPriceSource` | [src/PythPriceSource.sol](src/PythPriceSource.sol) | Pyth adapter: the latest price, or the first print at or after a time |
| Front-end | [frontend/](frontend/) | The page above; ABI generated from the build output |
| Backend | [validation/](validation/) | Recorder, relayer, keeper, API. The same folder holds the research engine and vault simulation behind the design |

Stack: Solidity 0.8.28 with Foundry (OpenZeppelin 5.1, Pyth SDK 2.2), Python 3.12 (eth-account, eth-abi),
Vite + React + TypeScript + viem.

## Correctness

| Check | What it guards |
|---|---|
| T1, T3, T7 | Exact constant-rate accrual. Touch-path independence (fuzzed, with feed posts in between). `\|p\| ≤ w` and `\|Δp\| ≤ V·Δt`. |
| T10 | Golden vectors from a Python reference that integrates second by second with exact rationals (a different algorithm from the contract's closed form). |
| T2 | Random histories: USDC held = vault + escrow + deposits; open interest equals the positions; funding attribution balances. |
| T5 | Healthy positions are never liquidated (fuzzed both ways), plus a position exactly at the boundary. |
| T4 | [script/check-compile-fail.sh](script/check-compile-fail.sh): code mixing margin or unit types must not compile. |
| T6, T9, T11–T13 | Bad data reverts. Feed bounds and median. Price windows. Vault capacity. Two-step fills (only the first print fills; no gas limit can turn a fill into a refund). |
| Backend, front-end | Intent tests for the relayer, keeper and Hermes client (the API key is never forwarded on a redirect), path traversal, the chart arithmetic and receipt decoding. |

Every test states the bug it would catch. [script/mutation-check.sh](script/mutation-check.sh) breaks 12
protections one at a time and requires the suite to fail each time (12 of 12 caught). The CI workflow
([.github/workflows/test.yml](.github/workflows/test.yml)) runs the format and compile-fail checks, the
golden-vector check, and the Forge, front-end and Python tests (the mutation check and the indexer's tests run
locally, as in [Run it yourself](#run-it-yourself)); its runs are currently not starting because of a billing
lock on the GitHub account, not because of test failures.

## Run it yourself

Prerequisites: [Foundry](https://getfoundry.sh), Node 22, pnpm (for the indexer), Python 3.11+.

```bash
git clone https://github.com/dylantlwu/continuous-funding && cd continuous-funding
git submodule update --init --recursive
forge test                                    # contracts
bash script/check-compile-fail.sh             # T4
python3 -m venv validation/.venv && validation/.venv/bin/pip install -r validation/requirements.txt
validation/.venv/bin/python -m unittest discover -s validation/tests -t .
npm ci --prefix frontend && npm test --prefix frontend
(cd indexer && pnpm install && pnpm test)        # Envio indexer
```

**Front-end against the live backend:** `npm --prefix frontend run dev` (it proxies `/api` to the deployed backend).

**Deploy** (testnet only). Put `PRIVATE_KEY`, `DEPLOYER`, `MONAD_TESTNET_RPC` and `PYTH_API_KEY` in `.env`
(see [.env.example](.env.example)); `.env` is gitignored. Then:

```bash
forge clean && forge script script/Deploy.s.sol --rpc-url $MONAD_TESTNET_RPC --broadcast --slow --gas-estimate-multiplier 200
```

**Backend** (validation/service.py) environment:

| Variable | Meaning |
|---|---|
| `PERP_ENGINE` | Engine address; everything else is read from chain |
| `MONAD_RPC` | RPC URL. The deployed backend uses [Alchemy](https://www.alchemy.com)'s Monad testnet endpoint |
| `KEEPER_LOG_PAGE` | Blocks per `eth_getLogs` scan: 100 on the public RPC (default), 1,000 on Alchemy |
| `KEEPER_POST_WHEN_EMPTY` | `1` keeps posting `c` (on a move or hourly) when this market has no positions, for other readers of the feed; unset by default |
| `PRIVATE_KEY` | Must be the feed's relayer |
| `PYTH_API_KEY` | Hermes key; it stays on the server |
| `PUBLIC_API_ONLY=1` | Serve only the front-end and its API |

**Local rehearsals on a Monad testnet fork**: [script/rehearse-fork.sh](script/rehearse-fork.sh),
[script/rehearse-backend-fork.sh](script/rehearse-backend-fork.sh), [script/fork-stack.sh](script/fork-stack.sh).
They need a `.env` with a Pyth Hermes API key (Pyth requires one to fetch prices) and any private key: a new key
with no testnet MON works, because the fork funds it locally. Nothing is sent to the testnet.

## Trust model and known limits

- **One key.** The relayer, the keeper and the contracts' owner are one testnet key held by the backend. The
  relayer reports the five venue values: the contract takes their median and bounds the result, and every
  value is public in the feed's events. So the relayer is accountable, not trustless: it can misreport within
  the bounds, but not hide that it did. The owner can pause new opens and rotate the relayer, and nothing more.
  The way out of the single key is in [cre/](cre/): the same five values posted by a Chainlink CRE workflow, read by
  every node of a DON and agreed before signing, to a second feed with the same bounds. It has posted on Monad
  testnet in CRE simulation through Chainlink's MockKeystoneForwarder (for example
  [`0x528c9c81…`](https://testnet.monadvision.com/tx/0x528c9c816e2dd02f518482b1e0c92ad93b1038af283d45a330be619dff122984));
  a production DON deployment is not done, and the market still reads the Python relayer's feed.
- **Freshness of `c`.** Between posts (on a 0.25%-a-year move, or hourly), `c` stays at its last value,
  and a post never re-prices the past. With no positions the relayer does not post. After 75 minutes without a
  post the feed counts as stale and new commits are refused; closes and liquidations never wait for the feed.
- **Leverage and gaps.** Up to 25x: a 25x position is liquidated after a move of about 2%. Liquidations use a
  price at most 3 seconds old; a move larger than a position's remaining margin before it is liquidated is a
  shortfall the vault absorbs (emitted as an event).
- **Capacity can be occupied.** A hedged pair of accounts fills capacity without funding cost; the 10 BTC
  per-account cap makes that take many funded addresses, and a borrow fee (not implemented) would make it
  cost money over time.
- **`p` has memory.** When the book rebalances, `p` stays where it is until the opposite imbalance moves it,
  as in SIP-279.
- **Vault solvency.** If the vault cannot pay a winning close, the close reverts rather than paying less. The
  capacity rule keeps that out of reach. There is no insurance fund and no auto-deleveraging; shortfalls are
  emitted as events.
- **The vault's testnet P&L is negative, and that is expected.** On 2026-10-07 the activity strip shows
  −$1,383.83. Almost all of it is one 2 BTC test long, opened by the author to create the imbalance shown in the
  demo, that was held about 15 hours while BTC rose 1.1%: the trader made $1,869.50 on price and paid only
  $4.27 of funding. The rest: two small trades (−$11.26 for the vault), funding received on all closes ($4.35,
  including that $4.27), fees ($188.77) and the liquidated margin kept net of the keeper's reward ($303.81). Funding charges a crowded side over time; it does
  not stop the counterparty losing a single trade, and over 15 hours `p` had barely started to build.
- **Accrual price.** Funding between touches accrues at the price of the last touch; anyone can `poke` to
  refresh it.
- **Testnet only.** Not audited. Test USDC has no value.

## Path forward

- **The feed, for other Monad perps.** `c` is useful beyond this market: any vault-backed perp can anchor its
  own funding to it and keep charging its own imbalance premium on top. [docs/feed.md](docs/feed.md) shows the
  one-line read, exact accrual across posts, the on-chain bounds and how to check every reported value; the
  example there is compiled and tested. Since 2026-10-07 the relayer keeps `c` fresh whether or not this
  market has positions, so another market can read it today.
- **Fewer trusted parties.** Move the market onto the CRE edition of the feed once the workflow runs on a production
  DON, instead of one relayer key; separate keys for the owner, the relayer and the keeper.
- **The vault.** LP shares with a withdrawal rule that cannot front-run realised losses; a borrow fee on open
  interest so that occupying capacity costs money; an audit before any mainnet value.
- **Beyond crypto.** The same split carries to other assets: `c` becomes the asset's own carry and `p` is unchanged.
  For a stock, `c` is the USD short rate minus the expected dividend yield, and each dividend is paid from shorts
  to longs on the ex-date. Because `c` does not need a live price, funding keeps a defined anchor while the
  underlying market is closed. Not built here.

## Prior art

Continuous funding is not new, and this project does not claim it is.

- [Synthetix SIP-279](https://sips.synthetix.io/sips/sip-279/): the velocity model `p` follows.
- [Perpl](https://docs.perpl.xyz/exchange/funding) on Monad: cumulative funding index with lazy settlement.
- GMX V2: adaptive per-second funding.
- Synthetix v3: delayed (two-step) orders settled at a later oracle price.
- Pyth: `parsePriceFeedUpdatesUnique`, the first-print proof.
- dYdX, Hyperliquid and Binance: how venues compute and settle funding, studied in [validation/](validation/).

What is specific here: the bounded combination of a cross-venue anchor and an imbalance premium for a
vault-backed perp; the correctness design (types, rounding by which mistake must be impossible, two-step fills
at a proven first print); and running it on Monad.

## Prior work

The author published two repositories before the event (both created 2026-09-03). They supplied ideas, not code:

- [perp-funding-lab](https://github.com/dylantlwu/perp-funding-lab) argues that quoted funding rates are not
  comparable across venues because settlement intervals differ. That argument motivates the per-second
  normalisation and the cadence chart.
- [exchange-guardrails](https://github.com/dylantlwu/exchange-guardrails) encodes production incidents as types.
  The same idea, applied to margins, became `MarginStatic` and `MarginDynamic` here.

Everything in this repository was written during the event. It was developed in a local git repository from
2026-09-28 and published to GitHub on 2026-10-05, with that commit history unchanged.

## AI disclosure

This project was built with AI coding tools, as rule §4.1.4 requires us to disclose. The author is a CFA and a
market-making and arbitrage trader who previously ran a production perpetual exchange; he does not write code.

| Who | What they did |
|---|---|
| **Claude Code** (Anthropic) | Wrote all of the code, tests, scripts and documentation in this repository, under the author's direction. |
| **The author** | Made the domain decisions: funding as `c + p`, the ±5% band and the velocity, the vault's priority, the stress level, two-step fills, the relayer's posting policy, fees and parameters. He reviewed the results and traded on testnet. |
| **Independent AI review sessions** | Audited the contracts and reviewed the project as hackathon judges. Their findings were fixed and recorded in the commit history. |
| **Demo video** | The narration is synthetic speech in the author's own cloned voice (Volcengine voice cloning 2.0, trained on the author's English recordings) reading a script Claude drafted and the author approved; there is no music. The overlays and explanatory animation were written as code by Claude and rendered frame by frame. The product footage is real screen recording of the live app and its testnet transactions. |

Commits do not carry AI co-author trailers, at the author's preference; this section is the disclosure.

## Attribution

| Dependency | Licence |
|---|---|
| [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts) v5.1.0 | MIT |
| [forge-std](https://github.com/foundry-rs/forge-std) | MIT or Apache-2.0 |
| [Pyth SDK for Solidity](https://github.com/pyth-network/pyth-sdk-solidity) v2.2.0 | Apache-2.0 |
| [viem](https://viem.sh), [React](https://react.dev), [Vite](https://vite.dev), [eth-account](https://github.com/ethereum/eth-account), [eth-abi](https://github.com/ethereum/eth-abi) | MIT |
| Instrument Serif, DM Mono, Hanken Grotesk, via [Fontsource](https://fontsource.org) | SIL Open Font License 1.1 |
| [Envio HyperIndex](https://envio.dev) (`envio`, the indexer in `indexer/`) | Envio's own licence, not OSI-approved: self-hosting allowed, third-party hosting restricted |
| [Chainlink CRE SDK](https://docs.chain.link/cre) (`@chainlink/cre-sdk`, the workflow in `cre/`) | BUSL-1.1: non-production use granted; becomes MIT on 2029-05-20. Installed as a dependency, not redistributed |
| [zod](https://zod.dev) | MIT |

Data comes from the public APIs of Binance, OKX, Bybit, Hyperliquid and Bitget, and from [Pyth](https://pyth.network)
through Hermes.

## Licence

MIT, see [LICENSE](LICENSE).
