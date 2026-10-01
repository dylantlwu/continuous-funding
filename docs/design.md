# Design: vault-protecting funding on Monad

Status: draft for owner review (2026-10-01). Nothing here is implemented yet except the off-chain
validation engine and recorder under `validation/`.

## 1. What this is

A minimal perpetual futures market on Monad testnet where a **vault takes the other side of every
trade**, and the funding rate is

```
rate = c + p
c = cross-venue consensus funding (median of Binance, OKX, Bybit, Hyperliquid, Bitget), posted every minute
p = our own imbalance premium, updated every block from our long/short skew, |p| <= w
```

The goal is to **protect the vault**. Funding at a vault-backed venue has one job: manage the vault's
inventory. Charging only the market rate (`c`) leaves the vault holding whatever the crowd is doing,
and a median consensus even invites one-way arbitrage against the highest-paying venue. Charging
only an imbalance rate (as Synthetix V2, GMX V2 and LeverUp do) starts from a level unrelated to the
market, so arbitrageurs initially trade on the wrong side. Anchoring to `c` and adding a bounded
inventory premium `p` makes `p` a clean signal relative to the market: when our book leans one way,
our rate moves up to `w` away from the market, which is enough to pay arbitrageurs to take the other
side.

Evidence (simulation, not proof): `validation/vault_sim.py` replays September 2026 BTC prices and real
funding from five venues with a cost-aware arbitrageur model. Under persistent one-sided demand,
`c + p` with `w = 5%` APR cut the standard deviation of vault PnL by about 82% versus `rate = c`.
It does not help against fast-flipping momentum flow. Assumptions and limits are in the simulation
report; numbers in the README must come from runs committed with their data.

## 2. Prior art (what is not new)

- Synthetix Perps V2 funding velocity (SIP-279): imbalance drives the *change* of the rate.
- GMX V2 adaptive funding: per-second accrual, imbalance-driven, rate drifts over time.
- LeverUp (Monad): funding = k · u³ of the open-interest imbalance, per second, no external reference.
- Perpl (Monad): funding computed off-chain and set by a permissioned method every 8,571 blocks;
  lazy settlement through a cumulative sum (the same index technique we use).
- Rho Funding Index: open-interest-weighted Binance/Bybit/OKX funding, every 8 hours.
- Pendle Boros: funding-rate swaps, one market per venue.

What this project adds: the combination (market anchor + bounded per-block inventory premium) for a
vault-backed venue, and the data to justify its parameters.

## 3. Contracts

| Contract | Responsibility |
|---|---|
| `PerpEngine` | Vault (LP deposits and withdrawals), markets (BTC, ETH), isolated positions, funding index, liquidation. One contract so that all cash sits in one place and conservation is checkable. |
| `ConsensusFeed` | Receives `c` per market from the relayer, enforces bounds, keeps a cumulative integral of `c` over time. Separate contract so the trust boundary is explicit and auditable. |
| `PythPriceSource` | Adapter over Pyth pull oracle: applies the caller's signed price update, returns price and publish time. Behind an interface (`IPriceSource`) so it can be swapped for Pyth Pro or Supra. |
| `TestUSDC` | 6-decimal ERC-20 with an open faucet, testnet only. |

No proxies, no governance, no token. An `owner` can pause new opens and rotate the relayer address.

## 4. Units and precision

| Quantity | Representation |
|---|---|
| Collateral | `uint256` USDC base units (6 decimals) |
| Position size | `int256` base-asset units scaled 1e18; positive = long |
| Price | `uint256` USD per base unit scaled 1e18, converted from Pyth's `(price, expo)` at the boundary |
| Rates | `int256` fraction per second scaled 1e18; positive = longs pay |
| Funding index | `int256` USD per 1e18 size units, scaled 1e18 |

Everything inside is integer. Conversion to USDC happens only when cash moves, rounding against the
trader (charges round up, payouts round down), so the vault can never owe more than it holds.

Reference values: `w = 5%` APR = 1,585,489,599 (per second, 1e18 scale). Velocity "2% APR per hour at
full imbalance" expressed per block, assuming the nominal 300 ms block: 52,850 per block. At full
imbalance `p` needs about 30,000 blocks (~2.5 h) to go from 0 to `w`.

## 5. Funding mechanics

### 5.1 State per market

```
skew            = totalLong - totalShort            (size units)
p, lastPBlock   = premium and the block it was last updated
fundingIndex, lastIndexTime, lastPrice
cCumAtLastIndex = ConsensusFeed cumulative integral read at lastIndexTime
```

### 5.2 Per-block premium

`p` reacts to the skew every block. Between two touches the skew is constant (nothing traded), so
after `n = block.number - lastPBlock` blocks:

```
u     = clamp(skew / skewScale, -1, 1)
p_new = clamp(p + n * V_block * u, -w, +w)
```

This is exact for a constant skew, because a clamped linear walk stays at the bound once it reaches it.
`p` uses block numbers because Monad's `block.timestamp` has one-second resolution and 3–4 blocks
share a timestamp (Monad docs, Deployment Summary). Only the *speed* of `p` depends on the nominal
block time; a different block time changes how fast `p` climbs, never how much funding is owed.

### 5.3 Accrual uses elapsed seconds

Funding owed is time-based, like every venue we anchor to. On each touch:

```
dt        = block.timestamp - lastIndexTime
cIntegral = feed.cumulative(market, now) - cCumAtLastIndex        // ∫ c dt, exact across feed updates
pIntegral = mean(p over the n blocks) * dt                        // p's path is a clamped linear walk
fundingIndex += lastPrice * (cIntegral + pIntegral) / 1e18
```

`mean(p)` is computed in closed form for the clamped walk (linear part plus the part at the bound).
Using a cumulative integral of `c` (kept by the feed, updated on every post) means accrual is correct
even if several `c` posts happened since the last touch. This is the property test T3 checks:
touching the market in between must not change the result.

`lastPrice` is the price stored at the last touch. With a pull oracle there is no price between
touches; the error this introduces is second-order (rate × price change × time) and is disclosed.

### 5.4 Position funding and the vault

```
fundingOwed(position) = size * (fundingIndex - entryIndex) / 1e18     // >0: the position pays
```

Every trader's funding is settled against the vault, the only counterparty. Over all positions,
`Σ fundingOwed + vaultFundingReceived = 0` by construction; test T2 checks it on random histories.

### 5.5 Consensus feed (`c`) and its trust bounds

The relayer (our Railway service) computes, every minute, each venue's live predicted funding
normalised to per-second, and posts the median per market with the five raw values in calldata and an
event so anyone can recompute it from public venue data afterwards.

`post(market, ratePerSec, observedAt, venueRates[5])` is accepted only if:
- `msg.sender == relayer`;
- `observedAt` increases, is not in the future and is at most `maxDelay` (2 min) old;
- `|ratePerSec| <= cMax` (100% APR);
- `|ratePerSec - previous| <= maxStep` (10% APR per post).

What a compromised relayer can do: move `c` by at most 10% APR per minute, never beyond ±100% APR,
in public. The owner can pause posting and rotate the key. Next step after the hackathon: several
independent posters with an on-chain median, or venue funding feeds signed by an oracle network.

If no post arrives for `staleAfter` (5 min): `c` stays frozen at its last value (no jump) and the
market becomes **reduce-only** (closes and liquidations allowed, no new risk). Funding keeps accruing
with frozen `c` plus live `p`. (Owner decision pending, section 10.)

## 6. Margin: two types that cannot be mixed

| Type | Meaning | Changes when |
|---|---|---|
| `MarginStatic` (`type MarginStatic is uint256`) | Collateral the trader actually deposited into the position | open, add/remove margin, close; realised funding on those events |
| `MarginDynamic` (`type MarginDynamic is uint256`) | Margin the position *requires* at the current price: initial = notional / maxLeverage, maintenance = notional × mmr | every price change |

There is no conversion function between them. They meet only inside two comparison functions:

```
canOpen(MarginStatic deposit, MarginDynamic initialRequired) -> bool
isLiquidatable(MarginStatic deposit, int256 pnl, int256 fundingOwed, MarginDynamic maintenance) -> bool
```

`isLiquidatable` uses integer arithmetic only, with no division, so two implementations cannot
disagree at the boundary because of rounding (a lesson from the owner's previous engine). Test T4 compiles a file that assigns one type to the other and asserts the
compiler rejects it.

Parameters (owner-approved provisional values): max leverage 10x, maintenance margin 5%.

## 7. Liquidation: fail loud

`liquidate(market, account, priceUpdate)` is permissionless. Steps:

1. Apply the Pyth update; read price and publish time.
2. **Revert** if price is zero, publish time older than `maxPriceAge` (60 s), confidence wider than
   `maxConfBps` (50 bp) of price, the position does not exist, or any accounting invariant fails
   (for example the vault's cash below the sum of deposits it owes).
3. Accrue funding to now.
4. **Revert with `NotLiquidatable`** unless `deposit + pnl - fundingOwed < maintenance`.
5. Close at the oracle price. Liquidation fee (provisional 0.5% of notional) to the liquidator from the
   remaining equity; the rest to the vault. If equity is negative, the vault absorbs it and emits
   `Shortfall(market, account, amount)`. There is no insurance fund or auto-deleveraging; the
   shortfall ledger is explicit.

The engine never "skips" an inconsistent position and never substitutes a default price.

## 8. Risk limits on the vault

- Open interest cap per market and a skew cap (`|skew| <= skewCap`); trades that would exceed them
  revert (trades that reduce skew are always allowed).
- Withdrawals: vault NAV is its cash; trader unrealised PnL is not marked in. A withdrawal must leave
  cash ≥ `minBacking` × open notional (provisional 20%).

## 9. Gas on Monad

Monad charges the gas **limit**, not gas used. The frontend sends fixed per-function gas limits taken
from `forge test --gas-report` plus a small margin, never "estimate × 2". Every user call touches at
most one market, so accrual is O(1) regardless of how long nobody traded.

## 10. Decisions still open (owner)

1. Stale consensus: freeze `c` and go reduce-only after 5 min (proposed), or decay `c` to 0, or use `p` only.
2. Liquidation fee (proposed 0.5% of notional) and its split between liquidator and vault.
3. Open-interest cap, skew cap and `skewScale` for the demo (simulation used 100 BTC as scale).
4. Vault withdrawal rule (proposed: keep 20% of open notional in cash).
5. Confirm 10x max leverage and 5% maintenance margin.

## 11. Tests (each with a one-line "what bug this would miss")

| # | Test |
|---|---|
| T1 | Constant `c` and `p`: funding over N seconds equals rate × N exactly (integer equality). |
| T2 | Random histories: Σ trader funding + vault funding = 0; total USDC in the system is conserved. |
| T3 | Touching a market mid-way (with feed posts in between) leaves the final index unchanged. |
| T4 | A file mixing `MarginStatic` and `MarginDynamic` fails to compile; the script asserts the compiler error. |
| T5 | Fuzz: healthy positions cannot be liquidated. |
| T6 | Zero price, stale price, wide confidence, missing position, broken invariant: liquidation reverts. |
| T7 | Fuzz: `|p| <= w` always; per-block change of `p` never exceeds `V_block`. |
| T8 | Extreme sizes and prices: no overflow, rounding always against the trader. |
| T9 | Feed: unauthorised post, out-of-order, future, too old, beyond `cMax`, beyond `maxStep` all revert; stale feed makes the market reduce-only. |
| T10 | Golden vectors: the Python reference (`validation/`) and the contract produce the same funding for a recorded scenario. |

## 12. Deliberately not doing

Order book or matching engine; cross margin; multiple collateral assets; insurance fund and
auto-deleveraging (explicit shortfall ledger instead); governance, token, upgradeable proxies; fee
tiers; stock and commodity markets (their venue funding rules differ too much for a consensus to be
meaningful, see research notes); mainnet.

## 13. What a judge sees in the demo

1. A trader opens a large one-sided position. On the next block `p` starts moving; the dashboard shows
   `rate = c + p`, with `c` from five venues and the ±5% band.
2. The cumulative-funding chart: venues step at their settlement times, our rate accrues every second.
3. A liquidation attempt on a healthy position reverts with `NotLiquidatable`; the T4 compile failure.
4. Contract addresses, verified sources, and the relayer's public posts with raw venue values.
