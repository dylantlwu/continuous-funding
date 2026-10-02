// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// Cash in USDC base units (6 decimals). The only type that moves tokens.
type Usdc is uint256;
/// USD amount scaled 1e18, signed: PnL, funding, notional.
type UsdWad is int256;
/// Collateral the trader actually deposited into a position (USDC base units).
/// Changes only on open, close and add-margin. Never derived from price.
type MarginStatic is uint256;
/// Margin a position requires at the current price (USDC base units, rounded up).
/// Changes with every price. Never stored as if it were a deposit.
type MarginDynamic is uint256;

// Arithmetic only within one type: Usdc + UsdWad does not compile.
using {_addUsdc as +, _subUsdc as -, _ltUsdc as <, _gtUsdc as >} for Usdc global;
using {_addWad as +, _subWad as -, _ltWad as <} for UsdWad global;

function _addUsdc(Usdc a, Usdc b) pure returns (Usdc) { return Usdc.wrap(Usdc.unwrap(a) + Usdc.unwrap(b)); }
function _subUsdc(Usdc a, Usdc b) pure returns (Usdc) { return Usdc.wrap(Usdc.unwrap(a) - Usdc.unwrap(b)); }
function _ltUsdc(Usdc a, Usdc b) pure returns (bool) { return Usdc.unwrap(a) < Usdc.unwrap(b); }
function _gtUsdc(Usdc a, Usdc b) pure returns (bool) { return Usdc.unwrap(a) > Usdc.unwrap(b); }
function _addWad(UsdWad a, UsdWad b) pure returns (UsdWad) { return UsdWad.wrap(UsdWad.unwrap(a) + UsdWad.unwrap(b)); }
function _subWad(UsdWad a, UsdWad b) pure returns (UsdWad) { return UsdWad.wrap(UsdWad.unwrap(a) - UsdWad.unwrap(b)); }
function _ltWad(UsdWad a, UsdWad b) pure returns (bool) { return UsdWad.unwrap(a) < UsdWad.unwrap(b); }

/// Conversions. There is deliberately NO function between MarginStatic and MarginDynamic:
/// mixing "what the trader put in" with "what the position needs" is a production bug class
/// (wrong liquidation prices) that must fail to compile. They only meet in `Margin`.
library Units {
    uint256 internal constant USDC_TO_WAD = 1e12;

    error NegativeCash(int256 wad);

    function toWad(Usdc x) internal pure returns (UsdWad) {
        return UsdWad.wrap(SafeCast.toInt(Usdc.unwrap(x) * USDC_TO_WAD));
    }

    /// The single place where USD (1e18) becomes cash (1e6). Callers choose the rounding direction;
    /// payouts to traders round down, charges round up.
    function toUsdcDown(UsdWad x) internal pure returns (Usdc) {
        int256 v = UsdWad.unwrap(x);
        if (v < 0) revert NegativeCash(v);
        return Usdc.wrap(uint256(v) / USDC_TO_WAD);
    }

    function toUsdcUp(UsdWad x) internal pure returns (Usdc) {
        int256 v = UsdWad.unwrap(x);
        if (v < 0) revert NegativeCash(v);
        return Usdc.wrap(Math.ceilDiv(uint256(v), USDC_TO_WAD));
    }

    function deposit(Usdc x) internal pure returns (MarginStatic) {
        return MarginStatic.wrap(Usdc.unwrap(x));
    }

    /// Add-margin: the deposit grows by exactly the cash added.
    function addCash(MarginStatic x, Usdc y) internal pure returns (MarginStatic) {
        return MarginStatic.wrap(MarginStatic.unwrap(x) + Usdc.unwrap(y));
    }

    function cash(MarginStatic x) internal pure returns (Usdc) {
        return Usdc.wrap(MarginStatic.unwrap(x));
    }

    function staticWad(MarginStatic x) internal pure returns (UsdWad) {
        return toWad(Usdc.wrap(MarginStatic.unwrap(x)));
    }

    /// Required margin from a USD amount, rounded up (a requirement is never understated).
    function required(UsdWad x) internal pure returns (MarginDynamic) {
        return MarginDynamic.wrap(Usdc.unwrap(toUsdcUp(x)));
    }

    function dynamicWad(MarginDynamic x) internal pure returns (UsdWad) {
        return toWad(Usdc.wrap(MarginDynamic.unwrap(x)));
    }
}

/// The only two places where deposited and required margin meet. Integer arithmetic, no division,
/// so two implementations cannot disagree at the boundary because of rounding.
library Margin {
    function canOpen(MarginStatic deposited, MarginDynamic initialRequired) internal pure returns (bool) {
        return MarginStatic.unwrap(deposited) >= MarginDynamic.unwrap(initialRequired);
    }

    /// equity = deposited + pnl - fundingOwed; liquidatable iff equity < maintenance.
    function isLiquidatable(MarginStatic deposited, UsdWad pnl, UsdWad fundingOwed, MarginDynamic maintenance)
        internal
        pure
        returns (bool)
    {
        int256 equity = UsdWad.unwrap(Units.staticWad(deposited)) + UsdWad.unwrap(pnl) - UsdWad.unwrap(fundingOwed);
        return equity < UsdWad.unwrap(Units.dynamicWad(maintenance));
    }
}

library SafeCast {
    error IntOverflow(uint256 v);

    function toInt(uint256 v) internal pure returns (int256) {
        if (v > uint256(type(int256).max)) revert IntOverflow(v);
        return int256(v);
    }
}

/// Signed a*b/d with explicit rounding. Floor rounds toward -infinity, ceil toward +infinity.
/// Callers pick the direction that goes against the trader.
library WadMath {
    int256 internal constant WAD = 1e18;

    function _abs(int256 x) private pure returns (uint256) {
        return x >= 0 ? uint256(x) : uint256(-x);
    }

    function mulDivFloor(int256 a, int256 b, uint256 d) internal pure returns (int256) {
        bool neg = (a < 0) != (b < 0);
        uint256 m = Math.mulDiv(_abs(a), _abs(b), d, neg ? Math.Rounding.Ceil : Math.Rounding.Floor);
        return neg ? -SafeCast.toInt(m) : SafeCast.toInt(m);
    }

    function mulDivCeil(int256 a, int256 b, uint256 d) internal pure returns (int256) {
        bool neg = (a < 0) != (b < 0);
        uint256 m = Math.mulDiv(_abs(a), _abs(b), d, neg ? Math.Rounding.Floor : Math.Rounding.Ceil);
        return neg ? -SafeCast.toInt(m) : SafeCast.toInt(m);
    }
}
