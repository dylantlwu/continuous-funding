// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PerpEngine} from "../src/PerpEngine.sol";
import {ConsensusFeed} from "../src/ConsensusFeed.sol";
import {Config} from "../script/Config.sol";

/// Test-side view of script/Config.sol: the same values, never a second copy.
library TestParams {
    int256 internal constant YEAR = Config.YEAR;
    int256 internal constant APR_1PCT = Config.APR_1PCT;
    int256 internal constant W = Config.W;
    int256 internal constant V = Config.V;
    int256 internal constant SLEW = Config.SLEW;
    uint64 internal constant STALE_AFTER = Config.STALE_AFTER;

    function defaults() internal pure returns (PerpEngine.Params memory) {
        return Config.engineParams();
    }

    function newFeed(address relayer) internal returns (ConsensusFeed) {
        return Config.newFeed(relayer);
    }

    /// All five venues at the same rate, so the median is that rate.
    function venues(int256 r) internal pure returns (int256[5] memory v) {
        for (uint256 i = 0; i < 5; i++) {
            v[i] = r;
        }
    }
}
