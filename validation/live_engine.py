"""Live tracking from recorded predictions: what we would charge right now, and how well it tracks each venue.

Inputs: recorder snapshots (live predictions) + each venue's settled history (public API, cached).
Same formula as tracker.py, but the current period is run only up to "now".
Hyperliquid's predictedFundings reports the START of the current hour in nextFundingTime (checked 2026-09-30),
so next settlement times that are not in the future are rolled forward by whole intervals.
"""
import sqlite3
import statistics
import threading
import time

from . import tracker
from .recorder import DB
from .venues import SETTLED

MIN = 60_000
_cache, _lock = {}, threading.Lock()


def _settled(venue, base, symbol, start_ms, end_ms):
    key = (venue, base)
    with _lock:
        hit = _cache.get(key)
        if hit and time.time() - hit[0] < 300:
            return hit[1]
    fn = SETTLED[venue]
    try:
        rows = fn(base, start_ms, end_ms, symbol=symbol)
    except TypeError:          # adapters without a symbol override
        rows = fn(base, start_ms, end_ms)
    with _lock:
        _cache[key] = (time.time(), rows)
    return rows


def load(base, db_path=DB):
    db = sqlite3.connect(db_path)
    rows = db.execute("SELECT venue, symbol, ts_ms, rate, next_ms, interval_h FROM snapshots WHERE base=? ORDER BY venue, ts_ms", (base,)).fetchall()
    polls = db.execute("SELECT venue, MAX(ts_ms), ok, latency_ms, error FROM polls GROUP BY venue").fetchall()
    first = db.execute("SELECT MIN(ts_ms) FROM polls WHERE ok=1").fetchone()[0]
    series = {}
    for v, sym, ts, rate, nxt, ih in rows:
        if nxt <= ts and ih:
            step = int(ih * 3_600_000)
            nxt += ((ts - nxt) // step + 1) * step
        series.setdefault(v, {"symbol": sym, "snaps": []})["snaps"].append((ts, rate, nxt, ih))
    return series, polls, first


def _pred_path(snaps, t0, t1, until):
    """Prediction in force at each minute of (t0, t1] up to `until`, using only snapshots for settlement t1."""
    mine = [(ts // MIN, r) for ts, r, nxt, _ in snaps if abs(nxt // MIN - t1) <= 1]
    if not mine:
        return None, 0
    path, j, cur = [], 0, mine[0][1]
    for m in range(t0, min(t1, until)):
        while j < len(mine) and mine[j][0] <= m:
            cur = mine[j][1]
            j += 1
        path.append(cur)
    return path, sum(1 for ts, _ in mine if ts < t0)


def venue_track(v, info, base, first_ms, now_ms):
    """Periods since recording started. The period in progress when recording began is pro-rated:
    if 3 of 8 hours had passed, the fair share of that settlement is 5/8 of it (prediction scaled the same way)."""
    snaps = info["snaps"]
    settled = _settled(v, base, info["symbol"], first_ms - 2 * 86_400_000, now_ms)
    start_min = first_ms // MIN
    now_min = now_ms // MIN
    before = [m for m, _ in settled if m < start_min]
    after = [(m, r) for m, r in settled if m >= start_min]
    periods, notes = [], []
    period_start = before[-1] if before else None          # true start of the period in progress at recording start
    prev = start_min
    for t1, rate in after:
        full = t1 - (period_start if period_start is not None else prev)
        frac = (t1 - prev) / full if full > 0 else 1.0
        path, _ = _pred_path(snaps, prev, t1, t1)
        if path is None or len(path) < t1 - prev:
            notes.append(f"{v}: period ending minute {t1} had incomplete live predictions; filled forward")
            fill = path[-1] if path else rate
            path = (path or []) + [fill] * ((t1 - prev) - len(path or []))
        periods.append({"start": prev, "end": t1, "settled": rate * frac, "pred": [x * frac for x in path]})
        period_start, prev = t1, t1
    ongoing = None
    nxt_min = snaps[-1][2] // MIN
    if nxt_min > now_min:
        full = nxt_min - (period_start if period_start is not None else prev)
        frac = (nxt_min - prev) / full if full > 0 else 1.0
        path, _ = _pred_path(snaps, prev, nxt_min, now_min)
        if path:
            ongoing = {"start": prev, "end": nxt_min, "settled": None, "pred": [x * frac for x in path]}
    return periods, ongoing, notes, settled


def run_tracker(periods, ongoing, h_min=tracker.H_MIN):
    venue_cum = ours = 0.0
    inc, venue_steps = {}, []
    for p in periods + ([ongoing] if ongoing else []):
        length = p["end"] - p["start"]
        for i, m in enumerate(range(p["start"], p["start"] + len(p["pred"]))):
            pred = p["pred"][i]
            rho = pred / length + (venue_cum + pred * i / length - ours) / max(p["end"] - m, h_min)
            ours += rho
            inc[m] = rho
        if p["settled"] is not None:
            venue_cum += p["settled"]
            venue_steps.append((p["end"], venue_cum))
    return inc, venue_steps


def state(base, policy="median", db_path=DB, now_ms=None):
    now_ms = now_ms or int(time.time() * 1000)
    series, polls, first = load(base, db_path)
    if not series or first is None:
        return {"base": base, "error": "no data recorded for this market yet"}
    per, out_v, notes = {}, {}, []
    for v, info in series.items():
        periods, ongoing, n, settled = venue_track(v, info, base, first, now_ms)
        notes += n
        if not periods and not ongoing:
            continue
        inc, steps = run_tracker(periods, ongoing)
        per[v] = inc
        ts, rate, nxt, ih = info["snaps"][-1]
        out_v[v] = {"symbol": info["symbol"], "pred": rate, "interval_h": ih, "next_ms": nxt, "pred_per_h_bp": 1e4 * rate / ih if ih else None,
                    "last_seen_ms": ts, "steps": [(m * MIN, 1e4 * c) for m, c in steps],
                    "tracker_start_ms": (periods[0]["start"] if periods else ongoing["start"]) * MIN,
                    "settled_recent": [(m * MIN, 1e4 * r) for m, r in settled[-6:]]}
    if not per:
        return {"base": base, "error": "waiting for the first settlement after recording started", "venues": out_v}
    if policy.startswith("anchor_"):
        a = policy[len("anchor_"):]
        ours = per.get(a)
        if ours is None:
            return {"base": base, "error": f"{a} has no tracker for {base}"}
    else:
        ours = tracker.combine(per, "median" if policy == "median" else "midrange")
    mins = sorted(ours)
    cum, c = [], 0.0
    for m in mins:
        c += ours[m]
        cum.append(((m + 1) * MIN, 1e4 * c))
    step = max(1, len(cum) // 400)
    rate_now = ours[mins[-1]] * 60 * 1e4 if mins else None          # bp per hour, charged in the last minute
    consensus = [x["pred_per_h_bp"] for x in out_v.values() if x["pred_per_h_bp"] is not None]
    base_h = statistics.median(consensus) if consensus else None
    # per-venue tracking error at each settlement since tracking started
    oc = {m: v for m, v in zip([(m + 1) for m in mins], [x[1] for x in cum])}
    track_err = {}
    for v, info in out_v.items():
        errs, prev_m, prev_c = [], None, 0.0
        for t_ms, vc in info["steps"]:
            m = t_ms // MIN
            if m in oc and (prev_m is None or prev_m in oc or prev_m == mins[0]):
                ours_delta = oc[m] - (oc.get(prev_m, 0.0) if prev_m else 0.0)
                errs.append((t_ms, (vc - prev_c) - ours_delta))
            prev_m, prev_c = m, vc
        track_err[v] = errs[-12:]
    return {
        "base": base, "policy": policy, "now_ms": now_ms, "recording_since_ms": first,
        "ours": {"rate_per_h_bp": rate_now, "apr_pct": rate_now * 24 * 365 / 100 if rate_now is not None else None,
                 "consensus_per_h_bp": base_h, "correction_per_h_bp": (rate_now - base_h) if (rate_now is not None and base_h is not None) else None,
                 "cum": cum[::step] + ([cum[-1]] if cum and cum[-1] != cum[::step][-1] else [])},
        "venues": out_v, "tracking_error_bp": track_err,
        "health": {v: {"last_poll_ms": t, "ok": bool(ok), "latency_ms": lat, "error": err} for v, t, ok, lat, err in polls},
        "notes": notes[:20],
    }
