// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockPyth} from "@pythnetwork/pyth-sdk-solidity/MockPyth.sol";
import {ConsensusFeed} from "../src/ConsensusFeed.sol";
import {PerpEngine} from "../src/PerpEngine.sol";
import {PythPriceSource} from "../src/PythPriceSource.sol";
import {TestUSDC} from "../src/TestUSDC.sol";
import {Usdc} from "../src/lib/Units.sol";
import {TestParams} from "./Params.sol";

/// The engine through the real Pyth adapter (MockPyth stands in for the on-chain Pyth contract).
contract PythIntegrationTest is Test {
    MockPyth pyth;
    PerpEngine eng;
    TestUSDC usdc;
    ConsensusFeed feed;
    bytes32 constant BTC = bytes32(uint256(1));
    address trader = address(0xA11CE);
    address relayer = address(0xBEEF);
    int256[5] venues;

    function setUp() public {
        vm.warp(1_000_000);
        pyth = new MockPyth(60, 1 wei);
        usdc = new TestUSDC();
        feed = new ConsensusFeed(relayer, 100 * TestParams.APR_1PCT, 5 * TestParams.APR_1PCT, 120, 300);
        eng = new PerpEngine(IERC20(address(usdc)), feed, 0, new PythPriceSource(pyth, BTC), TestParams.defaults());
        deal(address(usdc), address(this), 1_000_000e6);
        usdc.approve(address(eng), type(uint256).max);
        eng.seedVault(Usdc.wrap(1_000_000e6));
        deal(address(usdc), trader, 100_000e6);
        vm.deal(trader, 1 ether);
        vm.prank(trader);
        usdc.approve(address(eng), type(uint256).max);
        vm.prank(relayer);
        feed.post(0, 0, uint64(block.timestamp), venues);
    }

    function _upd(int64 price8, uint64 t) internal view returns (bytes[] memory u) {
        u = new bytes[](1);
        u[0] = pyth.createPriceFeedUpdateData(BTC, price8, 0, -8, price8, 0, t);
    }

    // Without this, the engine could underpay Pyth (every trade reverts on testnet) or keep the trader's
    // excess native token.
    function test_engineForwardsOracleFeeAndRefundsExcess() public {
        bytes[] memory u = _upd(100_000e8, uint64(block.timestamp)); // built first: it is an external call
        uint256 before = trader.balance;
        vm.prank(trader);
        eng.open{value: 10}(1e18, Usdc.wrap(10_050e6), u);
        assertEq(before - trader.balance, 1, "only the 1 wei Pyth fee is spent");
        assertEq(address(eng).balance, 0, "the engine keeps no native token");
        assertEq(eng.lastPrice(), 100_000e18);
    }

    // Without this, a trader could resubmit an older signed Pyth update to close on a better price.
    // Through Pyth the stored newer price wins, so the option does not exist; the engine's own
    // older-than-last check (T11) is the second line for price sources without this property.
    function test_olderPythUpdateCannotRewindThePrice() public {
        uint64 t0 = uint64(block.timestamp);
        bytes[] memory old = _upd(100_000e8, t0);
        vm.prank(trader);
        eng.open{value: 1}(1e18, Usdc.wrap(10_050e6), old);
        vm.warp(t0 + 2);
        eng.poke{value: 1}(_upd(98_000e8, t0 + 2));

        vm.recordLogs();
        vm.prank(trader);
        eng.close{value: 1}(old);                  // resubmits the t0 update at 100,000
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 closePrice;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == PerpEngine.Closed.selector) {
                (, closePrice,,,,) = abi.decode(logs[i].data, (int256, uint256, int256, int256, uint256, uint256));
            }
        }
        assertEq(closePrice, 98_000e18, "closed at the newer stored price, not the resubmitted one");
    }
}
