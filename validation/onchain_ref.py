"""Independent reference for the on-chain funding accrual, used for golden vectors (test T10).

It deliberately uses a different algorithm from the contract. The contract integrates p with one
closed form per interval in truncating integer arithmetic. This reference walks every second with
exact rationals (fractions.Fraction) and splits a second where p reaches the bound. If the closed
form picked the wrong branch, the wrong sign or the wrong clock, the two would disagree by far more
than the rounding dust the test allows.

Spec constants are the contract's integers (rates per second x1e18):
  w = 5% APR = 1_585_489_599, V = 2% APR per hour at full imbalance = 176_166 per second^2.

Usage: python3 -m validation.onchain_ref  -> writes test/golden/funding_vectors.json
"""
import json
import random
from fractions import Fraction
from pathlib import Path

WAD = 10**18
YEAR = 365 * 86400
W = 1_585_489_599
V = 176_166
SKEW_SCALE = 100 * WAD
APR_1PCT = WAD // 100 // YEAR  # same integer as the Solidity tests


def slope(long_oi, short_oi):
    """s = V * clamp(skew / scale, -1, 1), truncated toward zero (the spec's integer slope)."""
    skew = long_oi - short_oi
    if skew >= SKEW_SCALE:
        return V
    if skew <= -SKEW_SCALE:
        return -V
    mag = V * abs(skew) // SKEW_SCALE
    return mag if skew >= 0 else -mag


def premium_by_seconds(p0, s, dt):
    """Walk dt one-second slices; return (exact integral, p at the end)."""
    area, p = Fraction(0), p0
    for _ in range(dt):
        q = p + s
        if -W <= q <= W:
            area += Fraction(p + q, 2)
        else:
            bound = W if q > W else -W
            f = Fraction(bound - p, s)          # fraction of this second until the bound
            area += Fraction(p + bound, 2) * f + bound * (1 - f)
            q = bound
        p = q
    return area, p


def run(events):
    """events: list of dicts with t, kind ('post'|'touch'), and rate or price/long/short."""
    c_rate, c_started = 0, False
    index, p = Fraction(0), 0
    last_price, last_t = 0, events[0]["t"]
    long_oi = short_oi = 0
    tol, out = 0, []
    c_area = Fraction(0)                         # integral of c since the last touch
    t_prev = events[0]["t"]
    for e in events:
        if c_started:
            c_area += c_rate * (e["t"] - t_prev)
        t_prev = e["t"]
        if e["kind"] == "post":
            c_rate, c_started = e["rate"], True
            continue
        p_area, p = premium_by_seconds(p, slope(long_oi, short_oi), e["t"] - last_t)
        index += Fraction(last_price) * (c_area + p_area) / WAD
        tol += last_price // WAD + 2             # per touch: truncated p-integral x price, plus the floor
        c_area, last_t, last_price = Fraction(0), e["t"], e["price"]
        long_oi, short_oi = e["long"], e["short"]
        out.append({"index": index, "p": p, "tol": tol})
    return out


def scenario(seed=7):
    """Hand-written edge cases first, then a seeded random tail."""
    t0 = 1_000_000
    ev = [   # rates stay inside the feed's bounds: first post one step (5%) from 0, then <= 5% per post and per minute
        {"t": t0, "kind": "post", "rate": 5 * APR_1PCT},
        {"t": t0, "kind": "touch", "price": 100_000 * WAD, "long": 60 * WAD, "short": 0},
        {"t": t0 + 600, "kind": "touch", "price": 100_000 * WAD, "long": 60 * WAD, "short": 0},
        {"t": t0 + 1800, "kind": "post", "rate": 7 * APR_1PCT},
        {"t": t0 + 4200, "kind": "touch", "price": 100_500 * WAD, "long": 60 * WAD, "short": 0},
        {"t": t0 + 13_200, "kind": "touch", "price": 99_000 * WAD, "long": 0, "short": 150 * WAD},  # p hits +w inside
        {"t": t0 + 13_200, "kind": "post", "rate": 2 * APR_1PCT},                                   # same second
        {"t": t0 + 33_200, "kind": "touch", "price": 99_000 * WAD, "long": 0, "short": 150 * WAD},  # +w to -w
        {"t": t0 + 33_207, "kind": "touch", "price": 98_765_432_109_876_543_210_987, "long": 37 * WAD, "short": 36 * WAD},
        {"t": t0 + 33_300, "kind": "post", "rate": 4 * APR_1PCT},                                   # two posts between
        {"t": t0 + 33_400, "kind": "post", "rate": -1 * APR_1PCT},                                  # touches
        {"t": t0 + 40_000, "kind": "touch", "price": 101_000 * WAD, "long": 0, "short": 0},
    ]
    rng = random.Random(seed)
    t, rate = ev[-1]["t"], -1 * APR_1PCT
    for _ in range(30):
        t += rng.randint(61, 5000)               # > 1 minute: a 5% move is inside the per-minute bound (integer slew)
        if rng.random() < 0.4:
            rate = max(-100 * APR_1PCT, min(100 * APR_1PCT, rate + rng.randint(-5, 5) * APR_1PCT))
            ev.append({"t": t, "kind": "post", "rate": rate})
        else:
            ev.append({"t": t, "kind": "touch", "price": rng.randint(60_000, 140_000) * WAD + rng.randint(0, WAD),
                       "long": rng.randint(0, 200) * WAD // 2, "short": rng.randint(0, 200) * WAD // 2})
    return ev


def main():
    ev = scenario()
    res = run(ev)
    floor = lambda x: x.numerator // x.denominator
    doc = {
        "note": "generated by validation/onchain_ref.py; exact-rational per-second reference",
        "t": [e["t"] for e in ev],
        "kind": [0 if e["kind"] == "post" else 1 for e in ev],
        "value": [str(e.get("rate", e.get("price"))) for e in ev],
        "longOI": [str(e.get("long", 0)) for e in ev],
        "shortOI": [str(e.get("short", 0)) for e in ev],
        "expIndex": [str(floor(r["index"])) for r in res],
        "expP": [str(r["p"]) for r in res],
        "tol": [str(r["tol"]) for r in res],
    }
    path = Path(__file__).resolve().parents[1] / "test" / "golden" / "funding_vectors.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(doc, indent=1) + "\n")
    print(f"wrote {path} ({len(ev)} events, {len(res)} touches); final index {floor(res[-1]['index'])}, p {res[-1]['p']}")


if __name__ == "__main__":
    main()
