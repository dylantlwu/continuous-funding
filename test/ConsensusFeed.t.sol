// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ConsensusFeed} from "../src/ConsensusFeed.sol";

/// T9: the consensus feed's trust bounds and time accounting.
contract ConsensusFeedTest is Test {
    ConsensusFeed feed;
    address relayer = address(0xBEEF);
    int256 constant YEAR = 365 days;
    int256 constant APR_1PCT = 1e18 / 100 / YEAR; // 1% APR per second, 1e18
    int256[5] venues;

    function setUp() public {
        vm.warp(1_000_000);
        feed = new ConsensusFeed(relayer, 100 * APR_1PCT, 5 * APR_1PCT, 120, 300);
    }

    function _post(int256 r, uint64 observedAt) internal {
        vm.prank(relayer);
        feed.post(0, r, observedAt, venues);
    }

    // Without this, anyone could set the funding rate that every trader pays.
    function test_onlyRelayerCanPost() public {
        vm.expectRevert(ConsensusFeed.NotRelayer.selector);
        feed.post(0, APR_1PCT, uint64(block.timestamp), venues);
    }

    // Without this, a replayed or reordered post could move c backwards in time.
    function test_outOfOrderFutureAndTooOldPostsRevert() public {
        _post(APR_1PCT, uint64(block.timestamp));
        vm.warp(block.timestamp + 60);
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(ConsensusFeed.NotNewer.selector, uint64(block.timestamp - 60), uint64(block.timestamp - 60)));
        feed.post(0, APR_1PCT, uint64(block.timestamp - 60), venues);

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(ConsensusFeed.InFuture.selector, uint64(block.timestamp + 1)));
        feed.post(0, APR_1PCT, uint64(block.timestamp + 1), venues);

        vm.warp(block.timestamp + 200);                               // newer than the last post, but 121 s old
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(ConsensusFeed.TooOld.selector, uint64(block.timestamp - 121), uint64(120)));
        feed.post(0, APR_1PCT, uint64(block.timestamp - 121), venues);
    }

    // Without this, an extreme venue rate in a squeeze would revert, the feed would go stale, and the market
    // would stop accepting risk exactly when it matters; instead the value is clamped and logged.
    function test_outOfRangeValuesAreClampedNotRejected() public {
        _post(500 * APR_1PCT, uint64(block.timestamp));              // first post: only the absolute cap
        assertEq(feed.rate(0), 100 * APR_1PCT);
        vm.warp(block.timestamp + 60);
        _post(-100 * APR_1PCT, uint64(block.timestamp));             // step cap: at most 5% per post
        assertEq(feed.rate(0), 95 * APR_1PCT);
    }

    // Without this, a post carrying an old observation time could rewrite funding already accrued.
    function test_integralSwitchesAtPostTimestampNotObservedAt() public {
        uint64 t0 = uint64(block.timestamp);
        _post(2 * APR_1PCT, t0);
        vm.warp(t0 + 100);
        _post(4 * APR_1PCT, t0 + 10);                                 // observed 90 s ago, posted now
        vm.warp(t0 + 150);
        int256 expected = 2 * APR_1PCT * 100 + 4 * APR_1PCT * 50;    // the switch happens at t0+100
        assertEq(feed.cumulative(0), expected);
    }

    // Without this, the market could not tell a live feed from a dead one.
    function test_staleAfterThreshold() public {
        assertTrue(feed.isStale(0));                                  // never posted
        _post(APR_1PCT, uint64(block.timestamp));
        vm.warp(block.timestamp + 300);
        assertFalse(feed.isStale(0));
        vm.warp(block.timestamp + 1);
        assertTrue(feed.isStale(0));
    }

    // Without this, the integral used for accrual could drift from the piecewise-constant c actually posted.
    function testFuzz_cumulativeEqualsPiecewiseSum(uint32[6] memory gaps, int16[6] memory steps) public {
        int256 r = 0;
        int256 expected;
        uint64 t = uint64(block.timestamp);
        for (uint256 i = 0; i < 6; i++) {
            int256 target = r + int256(steps[i]) * APR_1PCT / 1000;  // small moves, inside the step cap
            if (target > 100 * APR_1PCT) target = 100 * APR_1PCT;
            if (target < -100 * APR_1PCT) target = -100 * APR_1PCT;
            _post(target, t);
            r = feed.rate(0);
            uint64 gap = uint64(gaps[i] % 100) + 1;
            expected += r * int256(uint256(gap));
            t += gap;
            vm.warp(t);
        }
        assertEq(feed.cumulative(0), expected);
    }
}
