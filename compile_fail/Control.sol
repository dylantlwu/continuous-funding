// SPDX-License-Identifier: MIT
// CONTROL: correct usage. Must compile; proves the failures below come from the type errors, not imports.
pragma solidity 0.8.28;
import {MarginStatic, MarginDynamic, Usdc, UsdWad, Units, Margin} from "../src/lib/Units.sol";
contract Control {
    function ok(MarginStatic d, MarginDynamic r) external pure returns (bool) { return Margin.canOpen(d, r); }
    function cash(MarginStatic d) external pure returns (Usdc) { return Units.cash(d); }
}
