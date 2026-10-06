// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ConsensusFeed} from "../src/ConsensusFeed.sol";
import {CreFeedReceiver} from "../src/cre/CreFeedReceiver.sol";
import {IReceiver} from "../src/interfaces/IReceiver.sol";
import {TestParams} from "./Params.sol";

contract CreFeedReceiverTest is Test {
    ConsensusFeed feed;
    CreFeedReceiver receiver;
    address forwarder = address(0xF0);
    int256 constant APR_1PCT = TestParams.APR_1PCT;

    function setUp() public {
        vm.warp(1_000_000 - 3600); // deployed an hour ago, so a first post is not held back by the slew bound
        feed = TestParams.newFeed(address(this));
        receiver = new CreFeedReceiver(feed, 0, forwarder);
        feed.setRelayer(address(receiver));
        vm.warp(1_000_000);
    }

    function _report(uint64 observedAt, int256[5] memory v) internal pure returns (bytes memory) {
        return abi.encode(observedAt, v);
    }

    function _rates() internal pure returns (int256[5] memory v) {
        v = [1 * APR_1PCT, 3 * APR_1PCT, 2 * APR_1PCT, 5 * APR_1PCT, 4 * APR_1PCT];
    }

    // Without this, anyone could call onReport and post venue values in the DON's name, which is exactly the single
    // trusted poster the CRE workflow replaces.
    function test_onlyTheForwarderCanDeliver() public {
        vm.expectRevert(abi.encodeWithSelector(CreFeedReceiver.NotForwarder.selector, address(this)));
        receiver.onReport("", _report(uint64(block.timestamp), _rates()));
    }

    // Without this, a delivered report could fail to reach the feed, or reach it with the venues out of order: the
    // feed must take the median of exactly what the DON agreed on.
    function test_aDeliveredReportPostsTheMedian() public {
        vm.prank(forwarder);
        receiver.onReport("", _report(uint64(block.timestamp), _rates()));
        assertEq(feed.rate(0), 3 * APR_1PCT, "median of 1,3,2,5,4 % a year");
        assertEq(feed.lastPostTime(0), uint64(block.timestamp));
    }

    // Without this, the feed's bounds could be bypassed through the receiver: a report the feed refuses (here an
    // observation older than maxDelay) must revert rather than be swallowed.
    function test_aReportTheFeedRefusesReverts() public {
        uint64 maxDelay = feed.maxDelay();
        uint64 old = uint64(block.timestamp - maxDelay - 1);
        vm.expectRevert(abi.encodeWithSelector(ConsensusFeed.TooOld.selector, old, maxDelay));
        vm.prank(forwarder);
        receiver.onReport("", _report(old, _rates()));
    }

    // Without this, a truncated or garbled payload could post zeros as venue rates.
    function test_aMalformedReportReverts() public {
        vm.prank(forwarder);
        vm.expectRevert();
        receiver.onReport("", hex"1234");
    }

    // Without this, the forwarder would advertise a receiver it cannot deliver to (it checks ERC165 first), or the
    // switch from the simulation forwarder to the production one would be open to anyone.
    function test_interfaceAndForwarderSwitch() public {
        assertTrue(receiver.supportsInterface(type(IReceiver).interfaceId));
        assertTrue(receiver.supportsInterface(type(IERC165).interfaceId));
        vm.prank(address(0xBAD));
        vm.expectRevert(CreFeedReceiver.NotOwner.selector);
        receiver.setForwarder(address(0xF1));
        receiver.setForwarder(address(0xF1));
        assertEq(receiver.forwarder(), address(0xF1));
    }
}
