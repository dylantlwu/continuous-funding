// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PerpEngine} from "../src/PerpEngine.sol";
import {ConsensusFeed} from "../src/ConsensusFeed.sol";

/// Owner-confirmed parameters (2026-10-03), in one place for all tests.
library TestParams {
    int256 internal constant YEAR = 365 days;
    int256 internal constant APR_1PCT = 1e18 / 100 / YEAR;
    int256 internal constant W = 1_585_489_599; // 5% APR per second
    int256 internal constant V = 176_166; // 2% APR per hour at full imbalance, per second^2
    int256 internal constant C_MAX = 100 * APR_1PCT;
    int256 internal constant MAX_STEP = 5 * APR_1PCT; // per post
    int256 internal constant SLEW = (5 * APR_1PCT + 59) / 60; // per second, rounded up: 60 s allow a full step

    function defaults() internal pure returns (PerpEngine.Params memory p) {
        p.w = W;
        p.velocity = V;
        p.skewScale = 100e18;
        p.stressMove = 0.25e18;
        p.minSize = 0.001e18;
        p.initialMarginRate = 0.1e18;
        p.maintenanceMarginRate = 0.05e18;
        p.tradeFeeRate = 0.0005e18;
        p.liquidationFeeRate = 0.005e18;
        p.maxOpenConfRate = 0.01e18;
        p.maxPriceAge = 3;
    }

    function newFeed(address relayer) internal returns (ConsensusFeed) {
        return new ConsensusFeed(relayer, C_MAX, MAX_STEP, SLEW, 120, 300);
    }

    /// All five venues at the same rate, so the median is that rate.
    function venues(int256 r) internal pure returns (int256[5] memory v) {
        for (uint256 i = 0; i < 5; i++) {
            v[i] = r;
        }
    }
}
