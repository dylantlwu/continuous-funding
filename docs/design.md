# Design: vault-protecting funding on Monad

Status: designed 2026-10-01, implemented in `src/` (2026-10-03) with the tests listed in §11, and deployed on
Monad testnet three times, each version replaced after an independent review (v1 and v2 on 2026-10-05, v3 on
2026-10-06; addresses in the README, changes in §10). The 2026-10-01 design already fixed issues raised by
two independent reviews of the first draft (one clock instead of two, the free oracle option, liquidations
blocked by global checks, LP run risk, feed liveness).

## 1. What this is

A minimal perpetual futures market on Monad testnet where a **vault takes the other side of every
trade**, and the funding rate is

```
rate = c + p
c = cross-venue consensus funding (median of Binance, OKX, Bybit, Hyperliquid, Bitget), posted by a relayer (§5.4)
p = our own inventory premium, driven by our long/short skew, |p| <= w = 5% APR
```

The goal is to **protect the vault's inventory**. At a vault-backed venue, funding's job is to make
holding the crowded side cost something relative to the market, so that someone is paid to take the
other side. Charging only `c` leaves the vault holding whatever the crowd does. Charging only an
imbalance rate (Synthetix V2, GMX V2, LeverUp) starts from a level unrelated to the market, so
hedged traders initially take the wrong side. Anchoring to `c` makes `p` a clean inventory signal.

What funding does **not** do: it does not defend against fast, toxic flow. At 5% APR, `p` is about
1.4 bp per day; a momentum trader does not notice it. Toxic flow is handled by the capacity rule (§8),
trading fees and tight oracle freshness (§7), not by funding.

How much `p` reduces the vault's risk is **not yet measured reproducibly**, so no figure is claimed here. A
replay that counts needs arbitrage capacity that responds to arbitrage profit, a fixed window and a committed
data snapshot (open item, §10).

## 2. Prior art (what is not new)

- Synthetix Perps V2 funding velocity (SIP-279): imbalance drives the *change* of the rate.
- GMX V2 adaptive funding: per-second accrual, imbalance-driven, rate drifts over time.
- LeverUp (Monad): funding = k · u³ of the open-interest imbalance, per second, no external reference.
- Perpl (Monad): funding computed off-chain and set by a permissioned method every 8,571 blocks;
  lazy settlement through a cumulative sum (the same index technique used here).
- Rho Funding Index: open-interest-weighted Binance/Bybit/OKX funding, every 8 hours.
- Pendle Boros: funding-rate swaps, one market per venue.

What this project adds: a market anchor plus a bounded inventory premium for a vault-backed venue,
and the data used to choose its parameters.

## 3. Contracts

| Contract | Responsibility |
|---|---|
| `PerpEngine` | Vault cash (seeded by the owner, no LP shares yet), BTC market, isolated positions, two-step orders, funding index, liquidation. One contract so all cash is in one place and conservation is checkable. |
| `ConsensusFeed` | Receives `c` from the relayer, clamps it to bounds, keeps a cumulative integral of `c` over time. Separate so the trust boundary is explicit. |
| `PythPriceSource` | Adapter over the Pyth pull oracle behind `IPriceSource`: the latest price (bots) and the first price at or after a given time (order settlement), so it can be swapped for Pyth Pro or another source. |
| `TestUSDC` | 6-decimal ERC-20 with an open faucet, testnet only. |

No proxies, no governance, no token. The `owner` can pause new opens and rotate the relayer.

Off-chain, two services, both replaceable by anyone: the **relayer** posts venue rates to
`ConsensusFeed`; the **keeper** settles orders nobody else settled and liquidates. Both run from one
backend that holds the Pyth API key, so the browser never does (Pyth requires keeping the key out of
front-ends); the browser gets signed Pyth updates through that backend.

**On-chain only when necessary (owner, 2026-10-05).** Everything shown continuously is computed
off-chain from free reads: the five venue rates and their median (the recorder, every minute), the BTC
price (Pyth through the backend), and `p`, the funding index, PnL and liquidation prices (contract
views via `eth_call`). Transactions are sent only for: the relayer's posts (§5.4); order settlement, which
**the keeper sends as soon as the fill print exists** (anyone can, at the same price; the page settles from the
trader's wallet if the keeper has not 15 seconds after the fill time), so a trade takes one wallet
confirmation; and liquidations that a free `eth_call` simulation shows will succeed. Nothing is poked on a
timer.

## 4. Units, precision and types

Mixing units is a likelier bug than mixing margins, so units are types too (Solidity user-defined
value types, no implicit conversion; this stops *accidental* mixing, a deliberate `wrap`/`unwrap` still
compiles and is easy to grep for):

| Type | Meaning |
|---|---|
| `Usdc` (`uint256`) | cash, 6 decimals; only type that moves tokens |
| `UsdWad` (`int256`) | USD amounts scaled 1e18 (PnL, funding, notional) |
| `MarginStatic`, `MarginDynamic` | see §6 |

Size is `int256` base units ×1e18 (positive = long); price is USD per base unit ×1e18 converted from
Pyth's `(price, expo)` at the boundary; rates are fraction per second ×1e18 (positive = longs pay).
The only `UsdWad → Usdc` conversions live in one library with an explicit rounding direction. The
direction is chosen by which mistake must be impossible:
- **payouts** (PnL, funding owed, fees) round against the trader, so rounding never pays out cash the
  vault does not have;
- the **liquidation decision** rounds toward "healthy" (PnL up, funding down, maintenance down), so the
  protocol may liquidate a dust amount late but can never liquidate a position that is healthy in
  exact arithmetic. A test pins a position whose equity equals its maintenance margin to the wei.

Real losses beyond a position's margin are recorded as explicit shortfalls (§7).

Reference values: `w = 5%` APR = 1,585,489,599 per second (×1e18). Velocity "2% APR per hour at full
imbalance" = 176,166 per second per second (×1e18). At full imbalance `p` reaches `w` in 2.5 hours.

## 5. Funding mechanics: one clock

### 5.1 State per market

```
skew = totalLong - totalShort
p, lastTime                      // premium and the timestamp it refers to
fundingIndex, lastPrice
cCumAtLastTime                   // ConsensusFeed cumulative integral of c, read at lastTime
```

### 5.2 Premium and accrual, both in seconds

On every call that touches the market (so re-evaluated in every block that has a trade, a close, a
liquidation or a keeper poke), with `dt = block.timestamp - lastTime` and the skew constant since the
last touch:

```
u        = clamp(skew / skewScale, -1, 1)
p(t)     = clamp(p + V * u * t, -w, +w)        for 0 <= t <= dt     (V per second)
pIntegral = ∫ p(t) dt over [0, dt]             closed form: linear part + part at the bound
cIntegral = feed.cumulative(now) - cCumAtLastTime
fundingIndex += lastPrice * (cIntegral + pIntegral) / 1e18
p = p(dt); lastTime = now
```

Because `p` and accrual use the same clock and closed-form integrals, touching the market more or less
often cannot change what is owed beyond rounding dust, **at a given price** (T3). Several blocks share one second on Monad; within a second
`dt = 0`, nothing accrues and `p` does not move. The honest wording is **"re-evaluated every block,
accrued per second"**.

`lastPrice` is the price at the last touch; between touches a pull oracle has no price. The error is
rate × price change × time: negligible when the market is touched often, not negligible after a long
quiet stretch with a large move (for example about 0.6% of notional after a week at 100% APR with a 30%
move). Anyone can `poke` with a fresh price to keep it small; disclosed.

### 5.3 Position funding and the vault

```
fundingOwed(position) = size * (fundingIndex - entryIndex) / 1e18      // > 0: the position pays
```

All funding settles against the vault. T2 computes the vault's side independently as
`-skew × ΔfundingIndex` and checks it equals minus the sum over positions up to rounding dust that is
bounded and always in the vault's favour (not a tautology from computing one side as the residual).

### 5.4 Consensus feed (`c`)

The relayer reads each venue's live predicted funding, normalises it to per second and posts the five values.
**The median is computed on-chain** (`medianOf`, public). The relayer cannot post a number unrelated to the
values it reports, but it chooses those values: it is accountable, not trustless. Every reported value is
public in the feed's events.

When it posts (owner, 2026-10-05): before an open when the feed is older than 3 minutes (a commit requires a
fresh feed), and, while there is open interest or a pending order, whenever the venues' median has moved 0.25%
a year from `c` on chain, or at least hourly. The keeper checks every 30 seconds for free, off chain; the median
is first held to ±`cMax`, or venues beyond the cap would trigger a post on every check. A 2-minute timer came
first and was replaced the same day: each post costs about 0.0092 MON (90,509 gas, charged at the limit), so 720
a day is 6.65 MON. Replayed on 24 hours of the recorder's minute medians, move-or-hourly posts about 117 times a
day (about 1.1 MON), and the worst gap between `c` and the median falls from 1.34% to 0.25% a year, since a
jump is posted at the next check instead of waiting for the timer. A 0.25% gap is not worth farming: against
the 10 bp round-trip fee it takes about 146 days to break even. Reproduce with
`python3 script/replay_posting.py` (the day of medians is saved in `docs/data/`). With no positions it does not post: nothing
accrues, and every post is charged at its gas limit.
Between posts, `c` stays at its last value and open positions accrue at it; a post changes `c` from its own
timestamp onward and never re-prices the past.

`post(market, observedAt, venueRates[5])`:
- reverts if `msg.sender != relayer`, if `observedAt` is not newer than the last post, is in the future,
  or is more than 2 minutes old, or if a post already landed in this second;
- takes the median of the venues present (a venue can be marked missing; at least 3 are required;
  an even count averages the middle two, rounded toward zero);
- **clamps** (does not revert) the median to ±`cMax`, and the change to at most `maxSlewPerSec` × seconds
  since the previous post (since deployment for the first post; `c` starts at 0). The bound is on change over
  time, not per post, so one post after a quiet spell catches up as far as the elapsed time allows (v1 also
  capped each post at 5% APR, which let a rarely-posted `c` fall far behind the venues). Emits `Clamped`. Rejecting
  would make the feed go stale exactly in a squeeze, when venue rates can exceed any cap (Binance's BTC
  cap is 0.3% per 8h, about 330% APR);
- updates the cumulative integral at the post's own `block.timestamp`, never at `observedAt`, so a post
  cannot rewrite time already accrued.

Bounds (owner, 2026-10-03; per-post step removed 2026-10-05): `cMax` 100% APR, slew 5% APR per minute,
so ±100% takes at least 20 minutes from 0, publicly, whatever the relayer does. The trust gap is
disclosed: one relayer key, and `c` (up to ±100% APR) is much larger than the on-chain `p` (±5%). The
relayer can misreport venue values; it cannot hide that it did. Mitigations: on-chain median of logged
inputs, the slew bound, and owner pause and key rotation, though today the owner and the relayer are the
same testnet key, which makes the last two moot until the keys are split. Most venues do not serve the
history of their *predicted* funding; the recorder keeps it minute by minute, and publishing that archive,
so anyone can check each reported value afterwards, is planned, not done. After the hackathon: several
posters, or oracle-signed venue funding.

If no post arrives for 75 minutes the feed counts as stale: `c` stays frozen at its last value (no jump)
and new commits wait for the next post; the page asks the relayer to post first when the feed is within 5
minutes of going stale. Only the commit checks the feed, not the fill (v3), and closes and liquidations are
never blocked by it. v2 used 5 minutes, which contradicted the hourly posting: the feed looked dead between
posts, nearly every open needed a backend post first, and a commit in the last second could be refused at
the fill for a full refund.

## 6. Margin: two types that cannot be mixed

| Type | Meaning | Changes when |
|---|---|---|
| `MarginStatic` | Collateral the trader actually deposited into the position | open, add margin; settled at close or liquidation |
| `MarginDynamic` | Margin required at the current price: initial = notional / maxLeverage, maintenance = notional × mmr | every price change |

No conversion function exists. They meet only in `canOpen(...)` and `isLiquidatable(...)`, which use
integer arithmetic without division. Test T4 compiles a file that assigns one to the other and
asserts the compiler error. Parameters: 25x max leverage (4% initial margin), 2% maintenance margin (owner,
2026-10-06, so that a liquidation can happen on testnet within an ordinary day's move; 10x and 5% before v3).

## 7. Prices, trading and liquidation

**Closing the free oracle option with two-step orders (owner, 2026-10-05).** With a pull oracle the
caller chooses which signed price to submit. In a one-step design a trader can pick, within the
allowed age, whichever print pays best. A one-step window short enough to make that worthless (3 s) does
not work for people: measured from the builder's machine, fetching a Pyth update took 3–5 s and a Monad
RPC call 2–3 s, before anyone confirms in a wallet. So trades are two-step, as in Synthetix v3:
1. the trader **commits** (`commitOpen(size, margin)` or `commitClose()`): no price, the margin goes
   into escrow;
2. anyone **settles** (`settle(account, update)`) with the first Pyth print published at or after
   `commitTime + 2 s`. The contract asks Pyth to prove it is the first (`parsePriceFeedUpdatesUnique`:
   publishTime ≥ the fill time and the previous print before it), so neither the trader nor the settler
   has any choice of price. Checked against the Monad testnet Pyth contract: the first print fills, a
   later print is refused.

The 2-second delay means the trader cannot have seen the fill price when signing. An open that fails its
checks at the fill price is **rejected** rather than reverted, so no order can block the queue. A rejection
the trader cannot cause (vault capacity, oracle confidence, a pause) refunds the margin in full. The
feed's freshness is checked at the commit, not at the fill: otherwise a trader could commit in the last second
before the feed goes stale and, if the print went against them, settle while it is stale for a full refund. A margin shortfall keeps the open fee at the fill price and refunds the rest (2026-10-05): margin is
the trader's choice, and refunding it in full would make "commit just enough" a free option on the 2
seconds, filled when the print is favourable and refunded when it is not. Running out of gas inside that check
reverts the whole settlement instead of rejecting, so a trader settling their own order cannot refuse an
unfavourable fill by under-funding gas (the 63/64 rule already prevents it at today's costs; the check
keeps it so). An order nobody settles within 60 s can be cancelled and its margin returned; the keeper
settles every order, and anyone else can. Residual, disclosed: if every keeper is down, a trader can let
an unfavourable order expire.

Trades also execute at the oracle price moved by its confidence interval **against the trader**: buying
(open long, close short) at price + conf, selling at price − conf, plus a 5 bp open and close fee.

**Bots use the latest price.** Liquidation and `poke` take the latest Pyth price: no older than the last
price used, at most 3 seconds old (owner, 2026-10-03: liquidators get no wider window than traders).
Liquidation checks health at the confidence-adjusted price in the trader's favour (long: price + conf,
short: price − conf), so a wide-confidence wick cannot liquidate a healthy position. The deployed keeper's
latency probe measures each RPC call and the Pyth fetch on its host, and estimates the path from fetching the
price to sending the transaction (one fetch plus about seven calls, before inclusion): on the public RPC
(2026-10-05) 0.21 s per call and about 1.6 s; on Alchemy's Monad endpoint (2026-10-06) 0.01 s per call and about
0.4 s. The first testnet liquidation happened on 2026-10-07: the keeper liquidated a 25x test long in the block one
second after the first Pyth print below its line
([tx](https://testnet.monadvision.com/tx/0x23e85ca13478266450ffb277f408cf4fbb507eec8173386c797f9621a2f57935)).

**Why Monad.** Two-step settlement is standard; what Monad changes is how it feels. A commit lands in
about a second and the keeper can settle about a second after the fill time, so a trade fills a few
seconds after the click, at a price no one chose. With 2-second blocks the same flow takes several
blocks, and with 12-second blocks it is unusable for active trading.

Positions must be at least 0.001 BTC, so no dust position can sit unliquidatable and block the owner's
withdrawal, and at most 10 BTC per account (§8).

**Fail loud, without freezing risk reduction.**
- A liquidation **reverts** if the price is zero, older than allowed, older than the last used price,
  or the position does not exist; and with `NotLiquidatable` if `deposit + pnl − fundingOwed ≥
  maintenance` at the trader-favourable price. It never substitutes a default price.
- Global problems (feed stale, owner pause, vault capacity, §8) **pause new opens only**. Closes and
  liquidations always work, because they reduce risk. One exception, disclosed: if the vault's cash
  cannot pay a winning trader, the close reverts with `VaultInsolvent` rather than paying less silently
  (owner, 2026-10-03). §8's capacity rule is what keeps this out of reach.
- When a liquidation leaves negative equity, the vault absorbs it and emits `Shortfall(account, amount)`.
  No insurance fund and no auto-deleveraging yet; the shortfall ledger is explicit.

Liquidation is permissionless. The liquidator receives 0.5% of notional, paid by the vault even when the
trader's equity cannot cover it (so underwater positions still get liquidated; the uncovered part is in
the `Shortfall`). Any remaining equity goes to the vault.

## 8. Vault risk limits

- The vault is seeded by the owner; there are no LP shares, so nobody can withdraw ahead of traders'
  realised profits (a withdrawal at cash value would let LPs exit before losses land). The owner can
  withdraw only when open interest is zero.
- **Capacity rule (owner, 2026-10-03).** Every open must leave the vault solvent after a 25% adverse
  move with the *larger side* unhedged, net of the unrealised profit it already owes traders:
  `max(longOI, shortOI) × price × 25% ≤ vaultCash − max(0, unrealised trader PnL)`.
  The larger side, not today's skew, because closes can never be blocked: if one side leaves, the skew
  becomes the other side. A per-trade skew cap does not work for the same reason (an independent audit
  showed it could be walked to 10× its value by opening hedge legs and closing them). With a 1,000,000
  vault at 100,000 per BTC this is 40 BTC per side. Funding owed is not counted (small, disclosed).
- Why the larger side and not the net: a net (skew) rule checked at opens can be walked up without limit
  by opening hedged pairs and then closing one leg of each, because closes are never checked. The
  failure then is an insolvent vault. Counting the larger side bounds the worst case after any sequence
  of closes; its failure mode is a frozen book, not lost money.
- That failure mode is real: a hedged pair (one long account, one short account) occupies capacity at
  no funding cost, so an attacker can block new opens for the price of two fees. Mitigation (owner,
  2026-10-05): at most 10 BTC per account, so filling a side takes several funded addresses, each needing
  testnet gas from a captcha faucet. A determined attacker can still do it; a borrow fee on open interest
  (as on GMX) would make occupying capacity cost money over time, and is not implemented.
- Trades that reduce the larger side are always allowed; the capacity rule, not funding, is the
  defence against toxic flow.

## 9. Gas on Monad

Monad charges the gas **limit**, so every write sets its limit from the node's own estimate: plus 15% from the
browser, 5% for the relayer's post (its gas is the same every time), 30% for the keeper. Every call touches
one market; accrual is O(1).

Testnet receipts (v1, 2026-10-05; on Monad `gasUsed` equals the limit charged): feed `post` 75,406
(estimate × 1.05) · `commitOpen` 246,554 · `settle` (open, with Pyth verification) 544,601 · `commitClose`
96,709 · `settle` (close) 497,922 (estimate × 1.3). v2 feed `post`: 90,509 gas at 102 gwei, 0.0092 MON
(block 68,438,127), which is why `c` is posted on a move or hourly rather than on a timer (§5.4).

## 10. Decisions

Decided by the owner (2026-10-01 to 10-03): `w` 5% APR; velocity 2% APR per hour at full imbalance;
Pyth; the feed bounds and on-chain median (§5.4); the rounding rule (§4); the capacity rule at 25%
(§8); `VaultInsolvent` kept and disclosed; execution at price ± conf; two-step orders filled at the
first Pyth print 2 s after commit, cancellable after 60 s (§7); a 3-second window for the latest-price
paths; minimum size 0.001 BTC; liquidation reward paid by the vault, remaining equity to the vault.
After the fourth review (2026-10-05): the feed's bound is on change over time only (no per-post step);
`c` is posted while there is open interest, on a 0.25%-a-year move or hourly (decided the same day after a
2-minute timer); at most 10 BTC per account; a margin-shortfall
rejection keeps the open fee; the keeper settles orders as soon as the print exists (one wallet
confirmation per trade); the faucet stays open. After the fifth review (2026-10-06): the feed is stale after
75 minutes instead of 5, and a fill no longer re-checks it; max leverage 25x with 2% maintenance; a
simulation figure for vault risk was removed until it is reproducible.

Still provisional: fees (5 bp open/close, 0.5% liquidation); `skewScale` for the demo; scope cuts
(owner-seeded vault without LP shares, BTC only, no partial close, no remove-margin, owner pause instead
of a reduce-only state machine); and simulation before claims (arbitrage capacity that responds to
arbitrage profit, `w` and cost sweeps, comparison with the velocity-only rule and `rate = c`).

## 11. Tests (each with a one-line "what bug this would miss")

| # | Test |
|---|---|
| T1 | Constant `c` and `p`: funding over N seconds equals rate × N exactly. |
| T2 | Random histories, checked after every step: USDC held equals vault cash plus deposits; long and short open interest equal the positions; the vault's funding, integrated by the test as `-skew × ΔIndex` at every touch, equals minus the sum over positions of `size × (exit or current index − entry index)`. |
| T3 | Touching the market at arbitrary times (with feed posts in between) leaves the final index unchanged. |
| T4 | A file mixing `MarginStatic`/`MarginDynamic` (and one mixing `Usdc`/`UsdWad`) fails to compile; the script asserts the compiler errors. |
| T5 | Fuzz: healthy positions cannot be liquidated, at any price within the allowed age and confidence; clearly unhealthy ones can (so a contract that never liquidates fails). Plus one position exactly at the boundary. |
| T6 | Zero, stale, older-than-last and missing data revert; global problems do not block closes or liquidations; dust below the minimum size cannot be opened. |
| T7 | Fuzz: `|p| <= w`; `p` moves at most `V × dt`. |
| T8 | Extreme sizes and prices: no overflow; rounding always against the trader. |
| T9 | Feed: unauthorised, out-of-order, future, too-old or same-second posts revert; the applied rate is the on-chain median, and the backend's median matches it on 300 vectors; out-of-range values are clamped; the bound holds over time (5% APR per minute) and one post after a quiet spell catches up; the first post is bounded by the time since deployment; the integral switches at the post's timestamp. |
| T10 | Golden vectors: the Python reference and the contract produce the same funding for a recorded scenario. |
| T11 | Latest-price paths (liquidate, poke): any price older than 3 s or older than the last used price reverts; trades execute at price ± conf against the trader. |
| T12 | Vault capacity: open interest cannot be stacked on one side by opening and closing hedge legs; capacity is net of unrealised profit already owed; at most 10 BTC per account. |
| T13 | Two-step orders: only the first Pyth print at or after commit + 2 s fills (earlier and non-first prints are refused); a pinned fill does not rewind the latest price; expired orders can only be cancelled; one order per account; liquidation clears a pending close; no gas limit turns a fill into a rejection (an out-of-gas fill reverts the settlement); an order committed on a fresh feed fills even if the feed goes stale before settlement; rejections the trader cannot cause refund in full, a margin shortfall keeps the open fee. |

[script/mutation-check.sh](../script/mutation-check.sh) breaks 12 of these protections one at a time and requires
a failing test for each (12 of 12 caught, 2026-10-07; its first run found the missing out-of-gas test).

## 12. Deliberately not doing

Order book; cross margin; multiple collateral; LP shares (for now); insurance fund and auto-deleveraging;
governance, token, upgradeable proxies; fee tiers; stock and commodity markets; mainnet.

## 13. What a judge sees in the demo

1. A trader commits a large one-sided position from a wallet and it fills a few seconds later at the
   first Pyth print after commit + 2 s (shown next to that print); on the next touches `p` moves; the
   dashboard shows `rate = c + p` with `c` from five venues and the ±5% band.
2. Cumulative funding: venues step at their settlement times, ours accrues every second.
3. A liquidation of a healthy position reverts with `NotLiquidatable`; settling with any print other than
   the first is refused by Pyth; a stale price is rejected; the T4 compile failure.
4. Contract addresses, verified sources, and the relayer's public posts with the raw venue values.
