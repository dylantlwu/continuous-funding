"""How much does each venue revise its live funding prediction before settlement?

Reads validation/data/live.sqlite written by recorder.py. For every (venue, symbol, settlement) that has passed,
compares the prediction k minutes before settlement with the last prediction before settlement.
Revisions inside the final H_MIN (10) minutes are the only part the tracker cannot absorb in the same period.

    python3 -m validation.revisions
"""
import sqlite3
import statistics
import time

from .recorder import DB

LOOKBACK_MIN = (60, 30, 10, 1)


def value_at(series, t_ms):
    """series: sorted [(ts_ms, rate)] written on change. Value in force at t_ms, or None if nothing recorded yet."""
    v = None
    for ts, r in series:
        if ts > t_ms:
            break
        v = r
    return v


def analyse(db_path=DB, now_ms=None):
    now_ms = now_ms or int(time.time() * 1000)
    db = sqlite3.connect(db_path)
    first_poll = {v: t for v, t in db.execute("SELECT venue, MIN(ts_ms) FROM polls WHERE ok=1 GROUP BY venue")}
    rows = db.execute("SELECT venue, symbol, next_ms, ts_ms, rate FROM snapshots WHERE next_ms < ? ORDER BY venue, symbol, next_ms, ts_ms", (now_ms,)).fetchall()
    groups = {}
    for v, s, nxt, ts, r in rows:
        groups.setdefault((v, s, nxt), []).append((ts, r))
    per_venue = {}
    for (v, s, nxt), series in groups.items():
        # only periods we watched for the full lookback window
        if first_poll.get(v, now_ms) > nxt - max(LOOKBACK_MIN) * 60_000:
            continue
        final = value_at(series, nxt - 1)
        if final is None:
            continue
        rec = per_venue.setdefault(v, {k: [] for k in LOOKBACK_MIN} | {"distinct": []})
        for k in LOOKBACK_MIN:
            before = value_at(series, nxt - k * 60_000)
            if before is not None:
                rec[k].append(abs(final - before))
        rec["distinct"].append(len({r for _, r in series}))
    return per_venue


def main():
    res = analyse()
    if not res:
        print("no complete settlement periods recorded yet; let the recorder run past at least one settlement plus 60 minutes")
        return
    print("| venue | periods | distinct values per period (median) | " + " | ".join(f"|revision| last {k} min, median / p95 (bp)" for k in LOOKBACK_MIN) + " |")
    print("|---|---|---|" + "---|" * len(LOOKBACK_MIN))
    for v, rec in sorted(res.items()):
        cells = []
        for k in LOOKBACK_MIN:
            a = sorted(rec[k])
            cells.append(f"{1e4*statistics.median(a):.3f} / {1e4*a[int(0.95*(len(a)-1))]:.3f}" if a else "–")
        print(f"| {v} | {len(rec['distinct'])} | {statistics.median(rec['distinct']):.0f} | " + " | ".join(cells) + " |")


if __name__ == "__main__":
    main()
