"""Replays posting policies for c on a saved day of five-venue medians (docs/design.md §5.4).

    python3 script/replay_posting.py [docs/data/consensus_24h_20261005.json]

The data is /api/consensus/history?hours=24 as served on 2026-10-05: one median per minute (per second, 1e18).
COST is one ConsensusFeed.post on Monad testnet: 90,509 gas charged at 102 gwei (block 68,438,127).
"""
import json
import sys

YEAR_S = 31_536_000
COST_MON = 90_509 * 102e9 / 1e18


def replay(points, every_min=None, move_apr=None, heartbeat_min=None):
    """(posts a day, MON a day, mean |c - median| and worst gap in % a year), checking once a minute."""
    posts, c, last, gaps = 0, None, None, []
    for t_ms, m in points:
        if m is None:
            continue
        x, t = m * YEAR_S / 1e16, t_ms // 1000
        if c is not None:
            due = ((every_min and t - last >= every_min * 60) or (move_apr and abs(x - c) >= move_apr)
                   or (heartbeat_min and t - last >= heartbeat_min * 60))
            if not due:
                gaps.append(abs(x - c))
                continue
        c, last, posts = x, t, posts + 1
        gaps.append(0.0)
    days = (points[-1][0] - points[0][0]) / 86_400_000
    return posts / days, posts / days * COST_MON, sum(gaps) / len(gaps), max(gaps)


if __name__ == "__main__":
    pts = json.load(open(sys.argv[1] if len(sys.argv) > 1 else "docs/data/consensus_24h_20261005.json"))["points"]
    print(f"{'policy':<26}{'posts/day':>10}{'MON/day':>9}{'mean gap':>10}{'worst gap':>11}")
    for name, kw in [("every 2 min", dict(every_min=2)), ("every 10 min", dict(every_min=10)),
                     ("move 0.25% or hourly", dict(move_apr=0.25, heartbeat_min=60)),
                     ("move 0.5% or hourly", dict(move_apr=0.5, heartbeat_min=60))]:
        a, b, c, d = replay(pts, **kw)
        print(f"{name:<26}{a:>10.0f}{b:>9.2f}{c:>9.3f}%{d:>10.3f}%")
