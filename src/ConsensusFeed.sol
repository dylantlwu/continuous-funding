// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// Cross-venue consensus funding rate `c`, from venue rates posted by one relayer, with explicit trust bounds.
///
/// Rates are fractions per second scaled 1e18; positive means longs pay.
/// The relayer posts each venue's live predicted funding (normalised to per second); the MEDIAN is computed
/// here, so the relayer cannot post a free number: every input it reports is public and attributable.
/// The feed keeps the time integral of c so a market can accrue exactly across several posts
/// without being touched in between: ∫c dt over [t0, t1] = cumulative(t1) - cumulative(t0).
///
/// Trust bounds (what a compromised relayer can do): at most one post per second; each post moves c by at
/// most `maxStep` AND by at most `maxSlewPerSec` × seconds since the last post; never beyond ±`cMax`; c
/// starts at 0. Out-of-range values are CLAMPED, not rejected: rejecting would let the feed go stale
/// exactly during a squeeze, when venue rates can exceed any cap.
contract ConsensusFeed {
    uint256 public constant VENUES = 5; // Binance, OKX, Bybit, Hyperliquid, Bitget
    int256 public constant MISSING = type(int256).min; // a venue the relayer could not read
    uint256 public constant MIN_VENUES = 3;

    struct Feed {
        int256 rate; // current c, per second, 1e18
        int256 cum; // ∫ c dt up to lastPostTime (1e18-scaled fraction)
        uint64 lastPostTime; // block.timestamp of the last post: the integral switches here
        uint64 lastObservedAt; // when the relayer observed the venues for the last post
        bool initialized;
    }

    address public owner;
    address public relayer;
    bool public postingPaused;

    int256 public immutable cMax;
    int256 public immutable maxStep;
    int256 public immutable maxSlewPerSec;
    uint64 public immutable maxDelay;
    uint64 public immutable staleAfter;

    mapping(uint8 => Feed) internal feeds;

    event Posted(uint8 indexed market, int256 median, int256 applied, uint64 observedAt, int256[VENUES] venueRates);
    event Clamped(uint8 indexed market, int256 raw, int256 applied);
    event RelayerChanged(address relayer);
    event PostingPaused(bool paused);

    error NotOwner();
    error NotRelayer();
    error Paused();
    error NotNewer(uint64 observedAt, uint64 last);
    error InFuture(uint64 observedAt);
    error TooOld(uint64 observedAt, uint64 maxDelay);
    error SameSecond();
    error TooFewVenues(uint256 present);

    constructor(
        address relayer_,
        int256 cMax_,
        int256 maxStep_,
        int256 maxSlewPerSec_,
        uint64 maxDelay_,
        uint64 staleAfter_
    ) {
        owner = msg.sender;
        relayer = relayer_;
        cMax = cMax_;
        maxStep = maxStep_;
        maxSlewPerSec = maxSlewPerSec_;
        maxDelay = maxDelay_;
        staleAfter = staleAfter_;
    }

    function post(uint8 market, uint64 observedAt, int256[VENUES] calldata venueRates) external {
        if (msg.sender != relayer) revert NotRelayer();
        if (postingPaused) revert Paused();
        Feed storage f = feeds[market];
        if (f.initialized && observedAt <= f.lastObservedAt) revert NotNewer(observedAt, f.lastObservedAt);
        if (f.initialized && block.timestamp == f.lastPostTime) revert SameSecond();
        if (observedAt > block.timestamp) revert InFuture(observedAt);
        if (block.timestamp - observedAt > maxDelay) revert TooOld(observedAt, maxDelay);

        int256 median = medianOf(venueRates);
        int256 applied = _clamp(median, -cMax, cMax);
        int256 step = maxStep; // the first post moves c from 0 by at most one step
        if (f.initialized) {
            int256 slew = maxSlewPerSec * int256(uint256(block.timestamp - f.lastPostTime));
            if (slew < step) step = slew;
        }
        applied = _clamp(applied, f.rate - step, f.rate + step);

        // close the previous segment at THIS block's timestamp, so a post never rewrites accrued time
        if (f.initialized) f.cum += f.rate * int256(uint256(block.timestamp - f.lastPostTime));
        f.rate = applied;
        f.lastPostTime = uint64(block.timestamp);
        f.lastObservedAt = observedAt;
        f.initialized = true;

        if (applied != median) emit Clamped(market, median, applied);
        emit Posted(market, median, applied, observedAt, venueRates);
    }

    /// Median of the venues present (at least MIN_VENUES). Even count: mean of the middle two, rounded
    /// toward zero. Public so anyone can recompute c from the logged inputs.
    function medianOf(int256[VENUES] calldata v) public pure returns (int256) {
        int256[VENUES] memory a;
        uint256 n;
        for (uint256 i = 0; i < VENUES; i++) {
            if (v[i] == MISSING) continue;
            int256 x = v[i];
            uint256 j = n++;
            while (j > 0 && a[j - 1] > x) {
                a[j] = a[j - 1];
                j--;
            }
            a[j] = x;
        }
        if (n < MIN_VENUES) revert TooFewVenues(n);
        return n % 2 == 1 ? a[n / 2] : (a[n / 2 - 1] + a[n / 2]) / 2;
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
