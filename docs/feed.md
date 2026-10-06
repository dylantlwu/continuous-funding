# Reading the five-venue funding feed

`ConsensusFeed` publishes one number on Monad: `c`, the median of five venues' predicted BTC funding
(Binance, OKX, Bybit, Hyperliquid, Bitget), normalised to a rate per second. Continuous Funding charges
`rate = c + p`, where `p` is its own imbalance premium. Any other market can read `c` the same way: as an
anchor that ties its funding to the wider market, plus whatever premium it charges for its own inventory.

A vault-backed perp that charges only for its own imbalance starts from a level unrelated to the market,
so hedged traders can sit on the wrong side of it; one that charges only an external rate leaves the vault
holding whatever the crowd does. Anchoring to `c` and adding your own premium separates the two.

## Where

| | |
|---|---|
| Chain | Monad testnet (10143) |
| `ConsensusFeed` | [`0x4210FC24D1e0114AE3B3977301dDcbBbA252eF85`](https://testnet.monadvision.com/address/0x4210FC24D1e0114AE3B3977301dDcbBbA252eF85) (source verified, exact match) |
| Market id | `0` = BTC |
| Interface | [src/interfaces/IFundingFeed.sol](../src/interfaces/IFundingFeed.sol): copy this one file |

## Units

Rates are fractions **per second, scaled 1e18**; positive means longs pay. To get percent a year:
`rate × 31,536,000 / 1e16`. A venue's per-interval rate is converted by dividing by its interval in seconds,
so venues that settle hourly and every eight hours are compared on the same clock.

## One read

```solidity
import {IFundingFeed} from "./IFundingFeed.sol";

IFundingFeed feed = IFundingFeed(0x4210FC24D1e0114AE3B3977301dDcbBbA252eF85);
int256 c = feed.rate(0); // per second, 1e18
```

From a terminal:

```bash
cast call 0x4210FC24D1e0114AE3B3977301dDcbBbA252eF85 "rate(uint8)(int256)" 0 --rpc-url https://testnet-rpc.monad.xyz
```

## Accruing it exactly

`c` changes only when the relayer posts. `cumulative(0)` is the integral of `c` over time since the first
post, up to the current second, so a market that is touched rarely still charges exactly what `c` was in
between: keep the last value you saw and charge the difference.

```solidity
contract AnchoredMarket {
    IFundingFeed public immutable feed;
    int256 public lastCumulative;
    int256 public accruedC; // ∫ c dt charged so far, per unit of size (1e18)

    constructor(IFundingFeed f) { feed = f; lastCumulative = f.cumulative(0); }

    function touch() external {
        require(!feed.isStale(0), "anchor stale"); // your choice: this example refuses a frozen anchor
        int256 cum = feed.cumulative(0);
        accruedC += cum - lastCumulative;
        lastCumulative = cum;
    }
}
```

This exact contract is compiled and tested in [test/FeedIntegration.t.sol](../test/FeedIntegration.t.sol): it
accrues exactly across two posts it was not touched at, and it refuses a stale anchor.

## Bounds you can rely on

A post can only move `c` within limits enforced on chain, whatever the relayer sends:

| Bound | Value | Read it with |
|---|---|---|
| Range | `c` is clamped to ±100% a year | `cMax()` |
| Speed | at most 5% a year per minute since the previous post (the first post: since deployment) | `maxSlewPerSec()` |
| Freshness of a report | each post's observation is at most 2 minutes old, never in the future, never older than the last | `maxDelay()` |
| Quorum | at least 3 of the 5 venues must be present | `MIN_VENUES()` |
| Staleness | no post for 75 minutes: `isStale(0)` is true; `c` stays at its last value, no jump | `isStale(0)`, `staleAfter()` |

Out-of-range values are clamped, not rejected, so the feed does not go silent exactly when venue rates spike.

## Checking every value

The relayer reports the five venue rates and the contract computes the median, so nothing it reports is
hidden. Every post emits:

```solidity
event Posted(uint8 indexed market, int256 median, int256 applied, uint64 observedAt, int256[5] venueRates);
```

`venueRates` are in the order Binance, OKX, Bybit, Hyperliquid, Bitget (`type(int256).min` marks a venue that
could not be read). `medianOf(venueRates)` is public, so anyone can recompute `median` from the logged inputs;
`applied` differs from `median` only when a bound clamped it (a `Clamped` event is emitted too). The public RPC
serves at most 100 blocks per `eth_getLogs` query.

## Trust model, plainly

- **One relayer key** reports the venue values. It is accountable, not trustless: it can misreport within the
  bounds above, but every value it reports is public and attributable. The owner can pause posting and
  rotate the relayer.
- **When it posts.** Today the relayer posts while Continuous Funding has open positions: whenever the median
  moves 0.25% a year from the on-chain `c`, and at least hourly. With no open positions it does not post,
  and the feed goes stale after 75 minutes. A market relying on the feed needs the hourly heartbeat to run
  regardless of our book; that is a configuration change, not a contract change.
- **Testnet only, not audited.**

## Next

Several independent posters, or venue funding signed at the source, so that no single key can move `c`
within its bounds; more markets than BTC. If you run a market on Monad and want to read this feed, open an
issue in this repository.
