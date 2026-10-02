// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// Cross-venue consensus funding rate `c`, posted by one relayer, with explicit trust bounds.
///
/// Rates are fractions per second scaled 1e18; positive means longs pay.
/// The feed keeps the time integral of c so a market can accrue exactly across several posts
/// without being touched in between: ∫c dt over [t0, t1] = cumulative(t1) - cumulative(t0).
///
/// Trust bounds (what a compromised relayer can do): move c by at most `maxStep` per post and never
/// beyond ±`cMax`, publicly. Out-of-range values are CLAMPED, not rejected: rejecting would let the
/// feed go stale exactly during a squeeze, when venue rates can exceed any cap.
contract ConsensusFeed {
    uint256 public constant VENUES = 5; // Binance, OKX, Bybit, Hyperliquid, Bitget

    struct Feed {
        int256 rate;           // current c, per second, 1e18
        int256 cum;            // ∫ c dt up to lastPostTime (1e18-scaled fraction)
        uint64 lastPostTime;   // block.timestamp of the last post: the integral switches here
        uint64 lastObservedAt; // when the relayer observed the venues for the last post
        bool initialized;
    }

    address public owner;
    address public relayer;
    bool public postingPaused;

    int256 public immutable cMax;
    int256 public immutable maxStep;
    uint64 public immutable maxDelay;
    uint64 public immutable staleAfter;

    mapping(uint8 => Feed) internal feeds;

    event Posted(uint8 indexed market, int256 raw, int256 applied, uint64 observedAt, int256[VENUES] venueRates);
    event Clamped(uint8 indexed market, int256 raw, int256 applied);
    event RelayerChanged(address relayer);
    event PostingPaused(bool paused);

    error NotOwner();
    error NotRelayer();
    error Paused();
    error NotNewer(uint64 observedAt, uint64 last);
    error InFuture(uint64 observedAt);
    error TooOld(uint64 observedAt, uint64 maxDelay);

    constructor(address relayer_, int256 cMax_, int256 maxStep_, uint64 maxDelay_, uint64 staleAfter_) {
        owner = msg.sender;
        relayer = relayer_;
        cMax = cMax_;
        maxStep = maxStep_;
        maxDelay = maxDelay_;
        staleAfter = staleAfter_;
    }

    function post(uint8 market, int256 ratePerSec, uint64 observedAt, int256[VENUES] calldata venueRates) external {
        if (msg.sender != relayer) revert NotRelayer();
        if (postingPaused) revert Paused();
        Feed storage f = feeds[market];
        if (f.initialized && observedAt <= f.lastObservedAt) revert NotNewer(observedAt, f.lastObservedAt);
        if (observedAt > block.timestamp) revert InFuture(observedAt);
        if (block.timestamp - observedAt > maxDelay) revert TooOld(observedAt, maxDelay);

        int256 applied = _clamp(ratePerSec, -cMax, cMax);
        if (f.initialized) applied = _clamp(applied, f.rate - maxStep, f.rate + maxStep);

        // close the previous segment at THIS block's timestamp, so a post never rewrites accrued time
        if (f.initialized) f.cum += f.rate * int256(uint256(block.timestamp - f.lastPostTime));
        f.rate = applied;
        f.lastPostTime = uint64(block.timestamp);
        f.lastObservedAt = observedAt;
        f.initialized = true;

        if (applied != ratePerSec) emit Clamped(market, ratePerSec, applied);
        emit Posted(market, ratePerSec, applied, observedAt, venueRates);
    }

    /// ∫ c dt from the first post up to now. Zero before the first post.
    function cumulative(uint8 market) public view returns (int256) {
        Feed storage f = feeds[market];
        if (!f.initialized) return 0;
        return f.cum + f.rate * int256(uint256(block.timestamp - f.lastPostTime));
    }

    function rate(uint8 market) external view returns (int256) {
        return feeds[market].rate;
    }

    /// No post for longer than `staleAfter`: c stays frozen at its last value (no jump);
    /// the engine pauses new opens but never blocks closes or liquidations.
    function isStale(uint8 market) external view returns (bool) {
        Feed storage f = feeds[market];
        return !f.initialized || block.timestamp - f.lastPostTime > staleAfter;
    }

    function lastPostTime(uint8 market) external view returns (uint64) {
        return feeds[market].lastPostTime;
    }

    function setRelayer(address relayer_) external {
        if (msg.sender != owner) revert NotOwner();
        relayer = relayer_;
        emit RelayerChanged(relayer_);
    }

    function setPostingPaused(bool p) external {
        if (msg.sender != owner) revert NotOwner();
        postingPaused = p;
        emit PostingPaused(p);
    }

    function _clamp(int256 x, int256 lo, int256 hi) private pure returns (int256) {
        return x < lo ? lo : (x > hi ? hi : x);
    }
}
