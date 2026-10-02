// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PerpEngine} from "../src/PerpEngine.sol";

/// Provisional parameters (design §10, pending owner confirmation), in one place for all tests.
library TestParams {
    int256 internal constant YEAR = 365 days;
    int256 internal constant APR_1PCT = 1e18 / 100 / YEAR;
    int256 internal constant W = 1_585_489_599;  // 5% APR per second
    int256 internal constant V = 176_166;        // 2% APR per hour at full imbalance, per second^2

    function defaults() internal pure returns (PerpEngine.Params memory p) {
        p.w = W;
        p.velocity = V;
        p.skewScale = 100e18;
        p.skewCap = 100e18;
        p.oiCap = 1_000e18;
        p.initialMarginRate = 0.1e18;
        p.maintenanceMarginRate = 0.05e18;
        p.tradeFeeRate = 0.0005e18;
        p.liquidationFeeRate = 0.005e18;
        p.maxOpenConfRate = 0.01e18;
        p.maxTradePriceAge = 3;
        p.maxLiquidationPriceAge = 10;
    }
}
