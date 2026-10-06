// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ConsensusFeed} from "../src/ConsensusFeed.sol";
import {IFundingFeed} from "../src/interfaces/IFundingFeed.sol";
import {TestParams} from "./Params.sol";

/// The integration pattern from docs/feed.md, compiled and run: a market that charges the feed's c (plus, in a
/// real market, its own premium), accruing c exactly across posts with cumulative().
contract AnchoredMarket {
    IFundingFeed public immutable feed;
    uint8 public constant BTC = 0;
    int256 public lastCumulative;
    int256 public accruedC; // ∫ c dt charged so far, per unit of size (1e18)

    constructor(IFundingFeed f) {
        feed = f;
        lastCumulative = f.cumulative(BTC);
    }

    /// Accrue c since the last touch. This example refuses a stale anchor rather than charge a frozen rate.
    function touch() external {
        require(!feed.isStale(BTC), "anchor stale");
        int256 cum = feed.cumulative(BTC);
        accruedC += cum - lastCumulative;
        lastCumulative = cum;
    }
}

contract FeedIntegrationTest is Test {
    ConsensusFeed feed;
    AnchoredMarket market;
    address relayer = address(0xBEEF);
    int256 constant APR_1PCT = TestParams.APR_1PCT;

    function setUp() public {
        vm.warp(1_000_000 - 3600); // deployed an hour ago, so the first post is not held back by the slew bound
        feed = TestParams.newFeed(relayer);
        vm.warp(1_000_000);
        _post(1 * APR_1PCT);
        market = new AnchoredMarket(IFundingFeed(address(feed)));
    }

    function _post(int256 r) internal {
        vm.prank(relayer);
        feed.post(0, uint64(block.timestamp), TestParams.venues(r));
    }

    // Without this, the interface integrators copy from docs/feed.md could drift from the deployed contract: a wrong
    // signature still compiles on their side and only fails on chain.
    function test_interfaceMatchesTheFeed() public view {
        IFundingFeed f = IFundingFeed(address(feed));
        assertEq(f.rate(0), feed.rate(0));
        assertEq(f.cumulative(0), feed.cumulative(0));
        assertEq(f.lastPostTime(0), feed.lastPostTime(0));
        assertEq(f.isStale(0), feed.isStale(0));
        assertEq(f.staleAfter(), TestParams.STALE_AFTER);
        assertEq(f.cMax(), feed.cMax());
        assertEq(f.maxSlewPerSec(), feed.maxSlewPerSec());
    }

    // Without this, the documented pattern (differences of cumulative) could miss or double-count the stretch
    // between two posts when the integrating market is not touched at the post.
    function test_anchoredMarketAccruesExactlyAcrossPosts() public {
        vm.warp(block.timestamp + 100);
        _post(2 * APR_1PCT); // c changes while the market is not touched
        vm.warp(block.timestamp + 50);
        market.touch();
        assertEq(market.accruedC(), 1 * APR_1PCT * 100 + 2 * APR_1PCT * 50);
    }

    // Without this, a market following the example could keep charging a frozen c after the relayer stopped.
    function test_aStaleAnchorIsRefused() public {
        vm.warp(block.timestamp + TestParams.STALE_AFTER + 1);
        vm.expectRevert(bytes("anchor stale"));
        market.touch();
    }
}
