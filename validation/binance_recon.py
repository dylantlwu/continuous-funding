"""Rebuild Binance's intraperiod predicted funding rate from its 1-minute premium index.

Formula from Binance's public FAQ (https://www.binance.com/en/support/faq/detail/360033525031, updated 2026-03-06):
  premium samples every 5 s; interval > 1h uses linearly increasing weights, 1h uses equal weights;
  F = [P + clamp(I - P, -0.05%, +0.05%)] / (8 / N), I = 0.01% per 8h, N = interval hours; then capped.
We only have one sample per minute (the kline close), so this is an approximation.
`validate()` measures how close the rebuilt final rate is to what Binance actually settled.
"""
DAMPER = 0.0005


def predicted_path(samples, interval_min, interest_8h=0.0001, cap=None):
    """samples: premium values in time order within one period. Returns predicted rate after each sample."""
    n_hours = interval_min / 60
    scale = n_hours / 8
    equal_weights = interval_min <= 60
    num = den = 0.0
    out = []
    for i, p in enumerate(samples, start=1):
        w = 1.0 if equal_weights else float(i)
        num += w * p
        den += w
        avg = num / den
        f = (avg + min(max(interest_8h - avg, -DAMPER), DAMPER)) * scale
        if cap is not None:
            f = min(max(f, -cap), cap)
        out.append(f)
    return out


def build_periods(settled, premium_by_min, interest_8h=0.0001, cap=None):
    """Turn settled [(minute, rate)] + premium {minute: value} into periods with a per-minute predicted path.

    The prediction used at minute m is the one computable from samples strictly before m (no look-ahead);
    before the first sample of a period it is the interest-only default for that interval.
    """
    periods = []
    for (t0, _), (t1, rate) in zip(settled, settled[1:]):
        length = t1 - t0
        mins = range(t0, t1)
        raw = [premium_by_min.get(m) for m in mins]
        missing = sum(v is None for v in raw)
        # carry forward across gaps; a period with no data at all is dropped loudly by the caller
        filled, last = [], None
        for v in raw:
            last = v if v is not None else last
            filled.append(last)
        if all(v is None for v in filled):
            periods.append({"start": t0, "end": t1, "settled": rate, "pred": None, "missing": missing})
            continue
        first = next(v for v in filled if v is not None)
        filled = [first if v is None else v for v in filled]
        after_each = predicted_path(filled, length, interest_8h, cap)
        default = interest_8h * (length / 60) / 8
        pred_at_min = [default] + after_each[:-1]          # known at the start of each minute
        periods.append({"start": t0, "end": t1, "settled": rate, "pred": pred_at_min,
                        "rebuilt_final": after_each[-1], "missing": missing})
    return periods


def validate(periods):
    errs = [(p["rebuilt_final"] - p["settled"]) for p in periods if p.get("pred")]
    dropped = sum(1 for p in periods if not p.get("pred"))
    if not errs:
        raise RuntimeError("no period could be rebuilt")
    a = sorted(abs(e) for e in errs)
    return {"periods": len(errs), "dropped": dropped,
            "mean_abs_bp": 1e4 * sum(a) / len(a), "p95_abs_bp": 1e4 * a[int(0.95 * (len(a) - 1))], "max_abs_bp": 1e4 * a[-1],
            "exact_share": sum(1 for x in a if x < 5e-9) / len(a)}
