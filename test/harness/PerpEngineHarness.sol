// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PerpEngine} from "../../src/PerpEngine.sol";
import {ConsensusFeed} from "../../src/ConsensusFeed.sol";
import {IPriceSource} from "../../src/interfaces/IPriceSource.sol";

/// Test-only access to the funding core, so T1/T3/T7/T10 can drive skew, premium and price directly
/// without oracle plumbing. Never deployed.
contract PerpEngineHarness is PerpEngine {
    constructor(ConsensusFeed feed_, Params memory p)
        PerpEngine(IERC20(address(0)), feed_, 0, IPriceSource(address(0)), p)
    {}

    function h_touch(uint256 price) external {
        _touch(price, uint64(block.timestamp)); // a fresh print
    }

    function h_setOI(uint256 l, uint256 s) external {
        longOI = l;
        shortOI = s;
    }

    function h_setPremium(int256 p) external {
        premium = p;
    }
}
