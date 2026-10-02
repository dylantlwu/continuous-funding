// SPDX-License-Identifier: MIT
// MUST FAIL: using a 1e18 USD amount as 6-decimal cash.
pragma solidity 0.8.28;
import {Usdc, UsdWad} from "../src/lib/Units.sol";
contract MixUnits {
    function bad(UsdWad pnl) external pure returns (Usdc) { return pnl; }
}
