"""Progressive true-up tracker: the funding rate our protocol charges, minute by minute.

For one reference venue, at each minute m of a period [start, end) of length L we charge
    rho = P / L  +  (T + P * (m - start) / L - A) / max(end - m, H_MIN)
where P = venue's current prediction for this period, T = venue settled cumulative, A = our cumulative.
First term: normal pace, the prediction spread evenly. Second term: correction of any deviation from that
ideal path (a prediction change, or a residual carried from the previous period), caught up over the time left
but never faster than over H_MIN minutes. With a stable prediction this is exact at every settlement; a change
inside the last H_MIN minutes leaves a residual that is carried into the next period and shrinks each period.
(An earlier version applied H_MIN to the whole gap and under-charged the last minutes of every period.)
Owner decision 2026-09-30: H_MIN = 10 minutes.
"""
import statistics

H_MIN = 10


def lagged_periods(settled, default_first=None):
    """Periods for a venue where we only know settled history: prediction = last settled rate, rescaled to this interval.
    Realistic (no look-ahead) but slower than a live prediction; the true-up still closes the gap one period later."""
    periods = []
    for i, ((t0, _), (t1, rate)) in enumerate(zip(settled, settled[1:])):
        length = t1 - t0
        if i == 0:
            guess = default_first if default_first is not None else settled[0][1]
        else:
            prev_len = t0 - settled[i - 1][0]
            guess = settled[i][1] * (length / prev_len)
        periods.append({"start": t0, "end": t1, "settled": rate, "pred": [guess] * length})
    return periods


def track(periods, h_min=H_MIN):
    """Returns {minute: rate charged during that minute} over the periods' span."""
    venue_cum = ours = 0.0
    inc = {}
    for p in periods:
        if p.get("pred") is None:
            raise ValueError(f"period {p['start']}-{p['end']} has no prediction; refusing to guess")
        length = p["end"] - p["start"]
        for i, m in enumerate(range(p["start"], p["end"])):
            pred = p["pred"][i]
            ideal = venue_cum + pred * i / length
            rho = pred / length + (ideal - ours) / max(p["end"] - m, h_min)
            ours += rho
            inc[m] = rho
        venue_cum += p["settled"]
    return inc


def combine(per_venue_inc, how):
    """Combine per-venue tracker rates minute by minute. Only minutes covered by every venue are kept."""
    common = set.intersection(*(set(d) for d in per_venue_inc.values()))
    out = {}
    for m in sorted(common):
        xs = [d[m] for d in per_venue_inc.values()]
        if how == "median":
            out[m] = statistics.median(xs)
        elif how == "midrange":
            out[m] = (min(xs) + max(xs)) / 2
        else:
            raise ValueError(how)
    return out
