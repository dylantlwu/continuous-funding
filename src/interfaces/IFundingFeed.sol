// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// Read side of ConsensusFeed, for markets that anchor their own funding to it (docs/feed.md).
/// Rates are fractions per second scaled 1e18; positive means longs pay. Market 0 is BTC.
/// Copy this file: it is all an integrator needs, and test/FeedIntegration.t.sol checks it against the feed.
interface IFundingFeed {
    /// c now: the median of the venues' last reported predicted funding, within the feed's bounds.
    function rate(uint8 market) external view returns (int256);

    /// ∫ c dt from the first post up to now. Accrue exactly across posts with cumulative(t1) - cumulative(t0).
    function cumulative(uint8 market) external view returns (int256);

    function lastPostTime(uint8 market) external view returns (uint64);

    /// No post for `staleAfter` seconds. c then stays at its last value; decide what your market does then.
    function isStale(uint8 market) external view returns (bool);

    function staleAfter() external view returns (uint64);

    /// c is clamped to ±cMax, and moves at most maxSlewPerSec × seconds since the previous post.
    function cMax() external view returns (int256);

    function maxSlewPerSec() external view returns (int256);
}
