// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PerpEngine} from "../src/PerpEngine.sol";
import {ConsensusFeed} from "../src/ConsensusFeed.sol";

/// The one place where deployed parameters live. Tests import this same library (as TestParams), so what
/// is tested is what is deployed. Owner decisions 2026-10-01 to 10-03; see docs/design.md §10.
library Config {
    int256 internal constant YEAR = 365 days;
    int256 internal constant APR_1PCT = 1e18 / 100 / YEAR; // 1% APR as a per-second rate, 1e18

    // funding
    int256 internal constant W = 1_585_489_599; // |p| <= 5% APR, per second
    int256 internal constant V = 176_166; // 2% APR per hour at full imbalance, per second^2
    // Full imbalance = the vault's capacity per side at launch (1,000,000 / (100,000 x 25%) = 40 BTC),
    // so "full" is reachable. Provisional: the owner may change it.
    uint256 internal constant SKEW_SCALE = 40e18;

    // consensus feed
    int256 internal constant C_MAX = 100 * APR_1PCT;
    int256 internal constant MAX_STEP = 5 * APR_1PCT; // per post
    int256 internal constant SLEW = (5 * APR_1PCT + 59) / 60; // per second, rounded up: 5% APR per minute
    uint64 internal constant MAX_DELAY = 120; // a post's observation may be at most 2 minutes old
    uint64 internal constant STALE_AFTER = 300; // no post for 5 minutes: opens pause

    // vault
    uint256 internal constant VAULT_SEED = 1_000_000e6; // test USDC

    function engineParams() internal pure returns (PerpEngine.Params memory p) {
        p.w = W;
        p.velocity = V;
        p.skewScale = SKEW_SCALE;
        p.stressMove = 0.25e18;
        p.minSize = 0.001e18;
        p.initialMarginRate = 0.1e18; // 10x
        p.maintenanceMarginRate = 0.05e18;
        p.tradeFeeRate = 0.0005e18; // 5 bp, provisional
        p.liquidationFeeRate = 0.005e18; // 0.5%, provisional
        p.maxOpenConfRate = 0.01e18;
        p.maxPriceAge = 3; // latest-price paths (liquidate, poke): bots only
        p.settleDelay = 2; // orders fill at the first Pyth price 2 s or more after commit
        p.orderTtl = 60; // unsettled after 60 s: the order may be cancelled and its margin refunded
    }

    function newFeed(address relayer) internal returns (ConsensusFeed) {
        return new ConsensusFeed(relayer, C_MAX, MAX_STEP, SLEW, MAX_DELAY, STALE_AFTER);
    }
}
