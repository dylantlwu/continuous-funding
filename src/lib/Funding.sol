// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// Closed-form premium path. p(t) = clamp(p0 + s*t, -w, +w) for t in [0, dt].
/// Units: p0, w are fractions per second (1e18); s is per second^2 (1e18); dt in seconds.
/// Returns the exact integral ∫ p(t) dt over [0, dt] (1e18-scaled fraction) and p(dt).
/// Because the integral is exact for any dt, splitting [0, dt] into pieces gives the same total up to
/// integer rounding, so how often the market is touched does not change what is owed (test T3).
/// All divisions here are of non-negative numbers, so Solidity's truncation equals floor; the Python
/// reference in validation/onchain_ref.py reproduces these values bit for bit (test T10).
library Funding {
    function premium(int256 p0, int256 s, int256 w, uint256 dt) internal pure returns (int256 integral, int256 p1) {
        if (p0 > w) p0 = w;
        if (p0 < -w) p0 = -w;
        if (dt == 0) return (0, p0);
        if (s == 0) return (p0 * int256(dt), p0);
        if (s < 0) {
            (int256 i, int256 q) = _rising(-p0, -s, w, int256(dt));
            return (-i, -q);
        }
        return _rising(p0, s, w, int256(dt));
    }

    /// s > 0, -w <= p0 <= w.
    function _rising(int256 p0, int256 s, int256 w, int256 dt) private pure returns (int256 integral, int256 p1) {
        int256 room = w - p0; // how far p can still rise
        if (s * dt <= room) {
            // never reaches the bound: p0*dt + s*dt^2/2
            return (p0 * dt + (s * dt * dt) / 2, p0 + s * dt);
        }
        // reaches w at tb = room/s, then stays: w*dt - room^2/(2s)
        return (w * dt - (room * room) / (2 * s), w);
    }
}
