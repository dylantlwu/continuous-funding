// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {MockPyth} from "@pythnetwork/pyth-sdk-solidity/MockPyth.sol";
import {PythPriceSource} from "../src/PythPriceSource.sol";

contract PythPriceSourceTest is Test {
    MockPyth pyth;
    PythPriceSource src;
    bytes32 constant BTC = bytes32(uint256(1));

    function setUp() public {
        vm.warp(1_000_000);
        pyth = new MockPyth(60, 1 wei);
        src = new PythPriceSource(pyth, BTC);
    }

    function _upd(int64 price, uint64 conf, int32 expo, uint64 t) internal view returns (bytes[] memory u) {
        u = new bytes[](1);
        u[0] = pyth.createPriceFeedUpdateData(BTC, price, conf, expo, price, conf, t);
    }

    // Without this, a Pyth exponent of -8 could be scaled wrongly and every price would be off by orders of magnitude.
    function test_convertsPythExponentToWad() public {
        (uint256 p, uint256 c, uint64 t) = src.update{value: 1}(_upd(83_500_12345678, 4_000_000_000, -8, uint64(block.timestamp)));
        assertEq(p, 83_500.12345678e18);
        assertEq(c, 40e18);
        assertEq(t, block.timestamp);
    }

    // Without this, a zero price could be used to value positions (T6: never substitute a bad price).
    function test_zeroPriceReverts() public {
        bytes[] memory u = _upd(0, 0, -8, uint64(block.timestamp));
        vm.expectRevert(abi.encodeWithSelector(PythPriceSource.NonPositivePrice.selector, int64(0)));
        src.update{value: 1}(u);
    }

    // Without this, the caller could underpay Pyth or lose any excess native token sent along.
    function test_feeIsChargedAndExcessRefunded() public {
        bytes[] memory u = _upd(1e8, 1e5, -8, uint64(block.timestamp));
        vm.expectRevert(abi.encodeWithSelector(PythPriceSource.InsufficientFee.selector, 0, 1));
        src.update(u);
        uint256 before = address(this).balance;
        src.update{value: 10}(u);
        assertEq(before - address(this).balance, 1);
    }

    receive() external payable {}
}
