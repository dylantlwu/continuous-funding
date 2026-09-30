"""How much funding can an arbitrageur extract by trading against us and hedging on venue X?

Gross funding only (no fees, no price basis). Positive = longs pay.
Per settlement period k of venue X, a trader long on us and short on X (or the reverse) earns
    D_k = rate_X,k - (our cumulative at t_k - our cumulative at t_{k-1})
and picks whichever side is positive, so |D_k| is the most he can make from that period.
Holding one side for the whole sample earns |sum D_k|: that is a persistent, repeatable arbitrage.
"""


def cumulative(inc):
    cum, c = {}, 0.0
    for m in sorted(inc):
        cum[m] = c          # cumulative charged before minute m
        c += inc[m]
    last = max(inc)
    cum[last + 1] = c
    return cum


def against(our_inc, venue_settled):
    cum = cumulative(our_inc)
    lo, hi = min(cum), max(cum)
    ds = []
    for (t0, _), (t1, rate) in zip(venue_settled, venue_settled[1:]):
        if t0 >= lo and t1 <= hi:
            ds.append(rate - (cum[t1] - cum[t0]))
    if not ds:
        raise ValueError("no overlapping periods")
    a = sorted(abs(d) for d in ds)
    days = (venue_settled[-1][0] - venue_settled[0][0]) / 1440
    return {"periods": len(ds),
            "mean_abs_bp": 1e4 * sum(a) / len(a),
            "p95_abs_bp": 1e4 * a[int(0.95 * (len(a) - 1))],
            "max_abs_bp": 1e4 * a[-1],
            "persistent_bp": 1e4 * sum(ds),
            "persistent_apr_pct": 100 * sum(ds) * 365 / max(days, 1e-9)}
