// SPDX-License-Identifier: MIT
// MUST FAIL: treating required margin as deposited margin (the production liquidation-price bug).
pragma solidity 0.8.28;
import {MarginStatic, MarginDynamic} from "../src/lib/Units.sol";
contract MixMargins {
    function bad(MarginDynamic required) external pure returns (MarginStatic) { return required; }
}
