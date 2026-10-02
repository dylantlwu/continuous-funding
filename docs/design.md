# Design: vault-protecting funding on Monad

Status: draft v2 for owner review (2026-10-01). v2 fixes the issues raised by two independent
reviews of v1 (one clock instead of two, the free oracle option, liquidations blocked by global checks,
LP run risk, feed liveness). Nothing here is implemented yet except the off-chain validation engine,
recorder and simulation under `validation/`.

## 1. What this is

A minimal perpetual futures market on Monad testnet where a **vault takes the other side of every
trade**, and the funding rate is

```
rate = c + p
c = cross-venue consensus funding (median of Binance, OKX, Bybit, Hyperliquid, Bitget), posted every minute
p = our own inventory premium, driven by our long/short skew, |p| <= w = 5% APR
```

The goal is to **protect the vault's inventory**. At a vault-backed venue, funding's job is to make
holding the crowded side cost something relative to the market, so that someone is paid to take the
other side. Charging only `c` leaves the vault holding whatever the crowd does. Charging only an
imbalance rate (Synthetix V2, GMX V2, LeverUp) starts from a level unrelated to the market, so
hedged traders initially take the wrong side. Anchoring to `c` makes `p` a clean inventory signal.

What funding does **not** do: it does not defend against fast, toxic flow. At 5% APR, `p` is about
1.4 bp per day; a momentum trader does not notice it. Toxic flow is handled by the skew cap (§8),
trading fees and tight oracle freshness (§7), not by funding.

Evidence so far (simulation, not proof): `validation/vault_sim.py` replays September 2026 BTC prices
and real funding from five venues. All four crowd scenarios must be reported together: compared with
`rate = c`, the hybrid lowered the standard deviation of vault PnL by 82% under persistent one-sided
demand, 18% under a shock, 6% under noise, and not at all under momentum. In that run the modelled
arbitrageurs lost money net of costs, so the next simulation makes arbitrage capacity respond to
arbitrage profit (open item, §10).

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
| `PerpEngine` | Vault cash (seeded by the owner, no LP shares in v1), BTC market, isolated positions, funding index, liquidation. One contract so all cash is in one place and conservation is checkable. |
| `ConsensusFeed` | Receives `c` from the relayer, clamps it to bounds, keeps a cumulative integral of `c` over time. Separate so the trust boundary is explicit. |
| `PythPriceSource` | Adapter over the Pyth pull oracle behind `IPriceSource`, so it can be swapped for Pyth Pro or Supra. |
| `TestUSDC` | 6-decimal ERC-20 with an open faucet, testnet only. |

No proxies, no governance, no token. The `owner` can pause new opens and rotate the relayer.

## 4. Units, precision and types

Mixing units is a likelier bug than mixing margins, so units are types too (Solidity user-defined
value types, no implicit conversion):

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
often cannot change what is owed (T3). Several blocks share one second on Monad; within a second
`dt = 0`, nothing accrues and `p` does not move. The honest wording is **"re-evaluated every block,
accrued per second"**.

`lastPrice` is the price at the last touch; between touches a pull oracle has no price. The error is
second-order (rate × price change × time) and is disclosed.

### 5.3 Position funding and the vault

```
fundingOwed(position) = size * (fundingIndex - entryIndex) / 1e18      // > 0: the position pays
```

All funding settles against the vault. T2 computes the vault's side independently as
`-skew × ΔfundingIndex` and checks it equals minus the sum over positions up to rounding dust that is
bounded and always in the vault's favour (not a tautology from computing one side as the residual).

### 5.4 Consensus feed (`c`)

The relayer computes, every minute, each venue's live predicted funding normalised to per second, and
posts the median with the five raw values in an event.

`post(market, ratePerSec, observedAt, venueRates[5])`:
- reverts if `msg.sender != relayer`, if `observedAt` is not newer than the last post, is in the future,
  or is more than 2 minutes old;
- **clamps** (does not revert) `ratePerSec` to ±`cMax` and to `previous ± maxStep`, emitting
  `ConsensusClamped`. Rejecting would make the feed go stale exactly in a squeeze, when venue rates
  can exceed any cap (Binance's BTC cap is 0.3% per 8h, about 330% APR);
- updates the cumulative integral at the post's own `block.timestamp`, never at `observedAt`, so a post
  cannot rewrite time already accrued.

Proposed bounds (owner decision, §10): `cMax` 100% APR, `maxStep` 5% APR per post (±100% reachable in
20 minutes, publicly). The trust gap is disclosed: one relayer key. Mitigations: public raw inputs,
owner pause and key rotation. Most venues do not serve the history of their *predicted* funding, so
the recorder's minute-by-minute data is archived publicly; that archive is what lets anyone recompute
`c` afterwards. After the hackathon: several posters with an on-chain median, or oracle-signed venue
funding.

If no post arrives for 5 minutes, `c` stays frozen at its last value (no jump) and the owner may pause
new opens. Closes and liquidations are never blocked by the feed.

## 6. Margin: two types that cannot be mixed

| Type | Meaning | Changes when |
|---|---|---|
| `MarginStatic` | Collateral the trader actually deposited into the position | open, close, add margin; realised funding at those events |
| `MarginDynamic` | Margin required at the current price: initial = notional / maxLeverage, maintenance = notional × mmr | every price change |

No conversion function exists. They meet only in `canOpen(...)` and `isLiquidatable(...)`, which use
integer arithmetic without division. Test T4 compiles a file that assigns one to the other and
asserts the compiler error. Provisional parameters: 10x max leverage, 5% maintenance margin.

## 7. Prices, trading and liquidation

**Closing the free oracle option.** With a pull oracle the caller chooses which signed price to submit.
Left open, a trader can pick the stale stored price or a fresh one, whichever pays, and a liquidator
can pick a wick. Rules:
- each market stores the last used `publishTime`; a submitted price must not be older than it;
- prices for opens and closes must be at most 3 seconds old; for liquidations at most 10 seconds old;
- an open and close fee (proposed 5 bp of notional, to the vault) makes residual picking unprofitable;
- liquidation checks health at the confidence-adjusted price in the trader's favour (long: price + conf,
  short: price − conf), so a wide-confidence wick cannot liquidate a healthy position.

Tight freshness windows are practical because Monad includes a transaction within about a second;
on slower chains a 3-second window would make normal trades fail. This is the most concrete "why
Monad" in the design.

**Fail loud, without freezing risk reduction.**
- A liquidation **reverts** if the price is zero, older than allowed, older than the last used price,
  or the position does not exist; and with `NotLiquidatable` if `deposit + pnl − fundingOwed ≥
  maintenance` at the trader-favourable price. It never substitutes a default price.
- Global problems (feed stale, vault cash below a threshold) **pause new opens only**. Closes and
  liquidations always work, because they reduce risk.
- When a liquidation leaves negative equity, the vault absorbs it and emits `Shortfall(account, amount)`.
  No insurance fund and no auto-deleveraging in v1; the shortfall ledger is explicit.

Liquidation is permissionless. Proposed fee 0.5% of notional to the liquidator, the rest of any
remaining equity to the vault.

## 8. Vault risk limits

- v1 vault is seeded by the owner; there are no LP shares, so nobody can withdraw ahead of traders'
  realised profits (a withdrawal at cash value would let LPs exit before losses land).
- Open-interest cap and skew cap (`|skew| <= skewCap`); trades that would exceed them revert, trades
  that reduce skew are always allowed. The skew cap, not funding, is the defence against toxic flow.
- Known cost of a skew cap: a hedged participant can occupy it for about `w` APR and crowd others out;
  disclosed, mitigated by keeping `w` small relative to the fee.

## 9. Gas on Monad

Monad charges the gas **limit**. The frontend sends fixed per-function limits from
`forge test --gas-report` plus a small margin. Every call touches one market; accrual is O(1).

Measured with a mock price source (so **excluding** Pyth's signature verification, which must be
measured on testnet with real update payloads before the limits are fixed), max over the test runs:
`open` 285,918 · `close` 192,523 · `liquidate` 214,350 · `poke` 141,749 · `addMargin` 53,897.

## 10. Open decisions (owner)

1. Feed bounds: `cMax` 100% APR and `maxStep` 5% APR per post?
2. Fees: open/close 5 bp; liquidation 0.5% of notional to the liquidator?
3. `skewScale`, skew cap and open-interest cap for the demo (simulation used 100 BTC as scale).
4. Scope cuts for a 6-day build (both reviewers): owner-seeded vault without LP shares; BTC only (ETH
   later); no partial close, no remove-margin; owner pause instead of a reduce-only state machine.
5. The fail-loud rule as refined in §7: position-level data problems revert; global problems only pause
   opens and never block closes or liquidations.
6. Simulation before claims: make arbitrage capacity respond to arbitrage profit, sweep `w` and costs,
   compare against the velocity-only rule as well as `rate = c`.

## 11. Tests (each with a one-line "what bug this would miss")

| # | Test |
|---|---|
| T1 | Constant `c` and `p`: funding over N seconds equals rate × N exactly. |
| T2 | Random histories, checked after every step: USDC held equals vault cash plus deposits; long and short open interest equal the positions; the vault's funding, integrated by the test as `-skew × ΔIndex` at every touch, equals minus the sum over positions of `size × (exit or current index − entry index)`. |
| T3 | Touching the market at arbitrary times (with feed posts in between) leaves the final index unchanged. |
| T4 | A file mixing `MarginStatic`/`MarginDynamic` (and one mixing `Usdc`/`UsdWad`) fails to compile; the script asserts the compiler errors. |
| T5 | Fuzz: healthy positions cannot be liquidated, at any price within the allowed age and confidence; clearly unhealthy ones can (so a contract that never liquidates fails). Plus one position exactly at the boundary. |
| T6 | Zero, stale, older-than-last and missing data revert; global problems do not block closes or liquidations. |
| T7 | Fuzz: `|p| <= w`; `p` moves at most `V × dt`. |
| T8 | Extreme sizes and prices: no overflow; rounding always against the trader. |
| T9 | Feed: unauthorised, out-of-order, future or too-old posts revert; out-of-range values are clamped; the integral switches at the post's timestamp. |
| T10 | Golden vectors: the Python reference and the contract produce the same funding for a recorded scenario. |
| T11 | Oracle option: a trade with a price older than 3 s or older than the last used price reverts. |

## 12. Deliberately not doing

Order book; cross margin; multiple collateral; LP shares (v1); insurance fund and auto-deleveraging;
governance, token, upgradeable proxies; fee tiers; stock and commodity markets; mainnet.

## 13. What a judge sees in the demo

1. A trader opens a large one-sided position; on the next touches `p` moves; the dashboard shows
   `rate = c + p` with `c` from five venues and the ±5% band.
2. Cumulative funding: venues step at their settlement times, ours accrues every second.
3. A liquidation of a healthy position reverts with `NotLiquidatable`; a stale price is rejected; the
   T4 compile failure.
4. Contract addresses, verified sources, the relayer's public posts with raw venue values, and the
   public archive of recorded venue predictions.
