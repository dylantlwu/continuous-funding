// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PythErrors} from "@pythnetwork/pyth-sdk-solidity/PythErrors.sol";
import {ConsensusFeed} from "../src/ConsensusFeed.sol";
import {PerpEngine} from "../src/PerpEngine.sol";
import {PythPriceSource} from "../src/PythPriceSource.sol";
import {TestUSDC} from "../src/TestUSDC.sol";
import {Usdc} from "../src/lib/Units.sol";
import {MockPythUnique} from "./harness/MockPythUnique.sol";
import {TestParams} from "./Params.sol";

/// The engine through the real Pyth adapter, with a mock that enforces Pyth's "first print" rule.
contract PythIntegrationTest is Test {
    MockPythUnique pyth;
    PerpEngine eng;
    TestUSDC usdc;
    ConsensusFeed feed;
    bytes32 constant BTC = bytes32(uint256(1));
    address trader = address(0xA11CE);
    address keeper = address(0x4EE9);
    address relayer = address(0xBEEF);
    uint64 t; // commit time

    function setUp() public {
        vm.warp(1_000_000);
        pyth = new MockPythUnique(60, 1 wei);
        usdc = new TestUSDC();
        feed = TestParams.newFeed(relayer);
        eng = new PerpEngine(IERC20(address(usdc)), feed, 0, new PythPriceSource(pyth, BTC), TestParams.defaults());
        deal(address(usdc), address(this), 1_000_000e6);
        usdc.approve(address(eng), type(uint256).max);
        eng.seedVault(Usdc.wrap(1_000_000e6));
        deal(address(usdc), trader, 100_000e6);
        vm.deal(keeper, 1 ether);
        vm.prank(trader);
        usdc.approve(address(eng), type(uint256).max);
        vm.prank(relayer);
        feed.post(0, uint64(block.timestamp), TestParams.venues(0));
        t = uint64(block.timestamp);
        vm.prank(trader);
        eng.commitOpen(1e18, Usdc.wrap(10_100e6));
        vm.warp(t + 2);
    }

    function _upd(int64 price8, uint64 publishTime, uint64 prev) internal view returns (bytes[] memory u) {
        u = new bytes[](1);
        u[0] = pyth.createUpdate(BTC, price8, 0, publishTime, prev);
    }

    // T13, the core claim. Without this, the settler (or the trader settling their own order) could pick
    // whichever print pays best. Only the FIRST print at or after commit + 2 s fills: an earlier print, or a
    // later one that is not the first, is refused by the oracle itself.
    function test_T13_onlyTheFirstPriceAfterTheDelayFills() public {
        bytes[] memory early = _upd(101_000e8, t + 1, t); // before the fill time
        bytes[] memory later = _upd(99_000e8, t + 3, t + 2); // a print at t + 2 came before it
        bytes[] memory first = _upd(100_000e8, t + 2, t + 1); // the first at or after t + 2
        vm.warp(t + 4);
        vm.startPrank(keeper);
        vm.expectRevert(PythErrors.PriceFeedNotFoundWithinRange.selector);
        eng.settle{value: 1}(trader, early);
        vm.expectRevert(PythErrors.PriceFeedNotFoundWithinRange.selector);
        eng.settle{value: 1}(trader, later);
        eng.settle{value: 1}(trader, first);
        vm.stopPrank();
        (,,, uint256 entry) = eng.positions(trader);
        assertEq(entry, 100_000e18, "filled at the first print after the delay");
    }

    // Without this, the engine could underpay Pyth (every settlement reverts on testnet) or keep the
    // settler's excess native token.
    function test_settlerPaysOracleFeeAndGetsExcessBack() public {
        bytes[] memory u = _upd(100_000e8, t + 2, t + 1); // built first: it is an external call
        uint256 before = keeper.balance;
        vm.prank(keeper);
        eng.settle{value: 10}(trader, u);
        assertEq(before - keeper.balance, 1, "only the 1 wei Pyth fee is spent");
        assertEq(address(eng).balance, 0, "the engine keeps no native token");
        assertEq(eng.lastPrice(), 100_000e18);
    }

    // Without this, settling an order with its pinned (older) print after a bot has used a newer price would
    // roll the accrual price back, and the next latest-price call would be judged against an older floor.
    function test_pinnedFillDoesNotRewindTheLatestPrice() public {
        bytes[] memory first = _upd(100_000e8, t + 2, t + 1);
        vm.warp(t + 5);
        eng.poke{value: 1}(_upd(98_000e8, t + 5, t + 4)); // a bot uses the newest price
        vm.prank(keeper);
        eng.settle{value: 1}(trader, first); // the order still fills at its own pinned print
        (,,, uint256 entry) = eng.positions(trader);
        assertEq(entry, 100_000e18);
        assertEq(eng.lastPrice(), 98_000e18, "accrual price stays at the newest");
        assertEq(eng.lastPublishTime(), t + 5);
    }

    // Without this, an older signed update resubmitted to the latest-price path could rewind the price.
    // Pyth keeps the newer stored price, so the older update is simply ignored.
    function test_olderPythUpdateCannotRewindTheLatestPrice() public {
        vm.warp(t + 5);
        bytes[] memory older = _upd(101_000e8, t + 3, t + 2);
        eng.poke{value: 1}(_upd(98_000e8, t + 5, t + 4));
        eng.poke{value: 1}(older);
        assertEq(eng.lastPrice(), 98_000e18);
    }
}
