// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ConsensusFeed} from "../src/ConsensusFeed.sol";
import {TestParams} from "./Params.sol";

/// T9: the consensus feed's trust bounds and time accounting.
contract ConsensusFeedTest is Test {
    ConsensusFeed feed;
    address relayer = address(0xBEEF);
    int256 constant APR_1PCT = TestParams.APR_1PCT;
    int256 constant M = type(int256).min; // MISSING

    function setUp() public {
        vm.warp(1_000_000);
        feed = TestParams.newFeed(relayer);
    }

    function _post(int256 r, uint64 observedAt) internal {
        vm.prank(relayer);
        feed.post(0, observedAt, TestParams.venues(r));
    }

    // Without this, anyone could set the funding rate that every trader pays.
    function test_onlyRelayerCanPost() public {
        vm.expectRevert(ConsensusFeed.NotRelayer.selector);
        feed.post(0, uint64(block.timestamp), TestParams.venues(APR_1PCT));
    }

    // Without this, a replayed or reordered post could move c backwards in time, and a burst of posts in one
    // second could step c many times at once.
    function test_outOfOrderFutureTooOldAndSameSecondPostsRevert() public {
        _post(APR_1PCT, uint64(block.timestamp - 5));
        int256[5] memory v = TestParams.venues(APR_1PCT);
        vm.prank(relayer);
        vm.expectRevert(ConsensusFeed.SameSecond.selector);
        feed.post(0, uint64(block.timestamp), v); // a newer observation, but the same second

        vm.warp(block.timestamp + 60);
        uint64 last = uint64(block.timestamp - 65); // the first post's observation time
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(ConsensusFeed.NotNewer.selector, last, last));
        feed.post(0, last, v);

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(ConsensusFeed.InFuture.selector, uint64(block.timestamp + 1)));
        feed.post(0, uint64(block.timestamp + 1), v);

        vm.warp(block.timestamp + 200); // newer than the last post, but 121 s old
        vm.prank(relayer);
        vm.expectRevert(
            abi.encodeWithSelector(ConsensusFeed.TooOld.selector, uint64(block.timestamp - 121), uint64(120))
        );
        feed.post(0, uint64(block.timestamp - 121), v);
    }

    // Without this, an extreme venue rate in a squeeze would revert, the feed would go stale, and the market
    // would stop accepting risk exactly when it matters; instead the value is clamped and logged.
    // The first post starts from 0, so a compromised relayer cannot open at the cap either.
    function test_outOfRangeValuesAreClampedNotRejected() public {
        _post(500 * APR_1PCT, uint64(block.timestamp)); // first post: one step from 0
        assertEq(feed.rate(0), 5 * APR_1PCT);
        vm.warp(block.timestamp + 60);
        _post(-100 * APR_1PCT, uint64(block.timestamp)); // one more step down
        assertEq(feed.rate(0), 0);
    }

    // F2 regression. Without this, a relayer posting once per second (or many times in one block) could walk
    // c to the cap in seconds; the bound must hold over TIME: at most 5% APR per minute.
    function test_slewBoundHoldsOverTime() public {
        _post(5 * APR_1PCT, uint64(block.timestamp));
        for (uint256 i = 0; i < 20; i++) {
            vm.warp(block.timestamp + 1);
            _post(100 * APR_1PCT, uint64(block.timestamp));
        }
        assertEq(feed.rate(0), 5 * APR_1PCT + 20 * TestParams.SLEW, "20 seconds buy 20 seconds of slew");
        assertLt(feed.rate(0), 7 * APR_1PCT);
    }

    // Without this, the relayer could post a number unrelated to the venue values it reports.
    function test_postAppliesTheMedianOfVenues() public {
        int256 p = APR_1PCT;
        vm.prank(relayer);
        feed.post(0, uint64(block.timestamp), [3 * p, p, 2 * p, 50 * p, -50 * p]);
        assertEq(feed.rate(0), 2 * p);
    }

    function test_medianIsComputedOnChain() public view {
        assertEq(feed.medianOf([int256(1), 2, 3, 1000, -1000]), 2, "outliers on both sides ignored");
        assertEq(feed.medianOf([int256(5), M, 1, M, 3]), 3, "missing venues skipped");
        assertEq(feed.medianOf([int256(4), 1, M, 2, 9]), 3, "even count: mean of the middle two");
        assertEq(feed.medianOf([int256(-4), -1, M, -1, -9]), -2, "-2.5 rounds toward zero");
    }

    // Without this, the backend's chart of c (validation/relayer.median_like_contract, which cannot call the
    // contract once per minute of history) could quietly use a different median rule from the one on chain.
    function test_backendMedianMatchesTheContract() public view {
        string memory j = vm.readFile("test/golden/median_vectors.json");
        int256[] memory flat = vm.parseJsonIntArray(j, ".venues");
        int256[] memory expected = vm.parseJsonIntArray(j, ".expected");
        for (uint256 i = 0; i < expected.length; i++) {
            int256[5] memory v = [flat[5 * i], flat[5 * i + 1], flat[5 * i + 2], flat[5 * i + 3], flat[5 * i + 4]];
            assertEq(feed.medianOf(v), expected[i]);
        }
    }

    // Without this, two venues (or one plus a missing one) could set c alone.
    function test_tooFewVenuesReverts() public {
        vm.expectRevert(abi.encodeWithSelector(ConsensusFeed.TooFewVenues.selector, 2));
        feed.medianOf([int256(1), M, M, 2, M]);
    }

    // Without this, a post carrying an old observation time could rewrite funding already accrued.
    function test_integralSwitchesAtPostTimestampNotObservedAt() public {
        uint64 t0 = uint64(block.timestamp);
        _post(2 * APR_1PCT, t0);
        vm.warp(t0 + 100);
        _post(4 * APR_1PCT, t0 + 10); // observed 90 s ago, posted now
        vm.warp(t0 + 150);
        int256 expected = 2 * APR_1PCT * 100 + 4 * APR_1PCT * 50; // the switch happens at t0+100
        assertEq(feed.cumulative(0), expected);
    }

    // Without this, the market could not tell a live feed from a dead one.
    function test_staleAfterThreshold() public {
        assertTrue(feed.isStale(0)); // never posted
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
            _post(r + int256(steps[i]) * APR_1PCT / 1000, t); // clamping, if any, is read back below
            r = feed.rate(0);
            uint64 gap = uint64(gaps[i] % 100) + 1;
            expected += r * int256(uint256(gap));
            t += gap;
            vm.warp(t);
        }
        assertEq(feed.cumulative(0), expected);
    }
}
