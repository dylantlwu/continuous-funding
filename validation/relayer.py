"""Relayer: posts the five venues' live predicted funding to ConsensusFeed, ONLY before an open
(owner decision 2026-10-05; docs/design.md §5.4). The median is computed on-chain; this only reports inputs.

Rates come from the recorder's SQLite (validation/recorder.py): a venue counts only if its last successful poll
is recent; otherwise it is reported as MISSING, and the contract needs at least three venues.
Each venue rate is per funding interval; it is normalised to a per-second rate scaled 1e18, the feed's unit.
"""
import threading

MISSING = -(2**255)  # ConsensusFeed.MISSING = type(int256).min
# Contract order (ConsensusFeed: Binance, OKX, Bybit, Hyperliquid, Bitget) and each venue's BTC symbol.
VENUES = [("binance", "BTCUSDT"), ("okx", "BTC-USDT-SWAP"), ("bybit", "BTCUSDT"),
          ("hyperliquid", "BTC"), ("bitget", "BTCUSDT")]
MAX_DELAY_S = 120  # ConsensusFeed maxDelay: an observation may be at most this old when posted
MIN_VENUES = 3

_post_lock = threading.Lock()


def median_like_contract(values):
    """ConsensusFeed.medianOf on the venues present: None below three; even count = mean of the middle two,
    rounded toward zero. Only for display history (one on-chain call per minute of history would be absurd);
    test/golden/median_vectors.json makes the Solidity suite check this against the contract itself."""
    a = sorted(values)
    n = len(a)
    if n < MIN_VENUES:
        return None
    if n % 2:
        return a[n // 2]
    s = a[n // 2 - 1] + a[n // 2]
    return abs(s) // 2 if s >= 0 else -(abs(s) // 2)


def consensus_history(db, now_ms, hours=24, step_s=60):
    """[(t_ms, median per-second rate 1e18 or None)] every `step_s` over the last `hours`, from the recorder.
    A venue carries its last recorded value forward (snapshots are written only on change). For the chart of
    settlement cadences; the on-chain c is whatever the relayer posted before each open."""
    start = now_ms - hours * 3_600_000
    series = []
    for venue, symbol in VENUES:
        prev = db.execute("SELECT ts_ms, rate, interval_h FROM snapshots WHERE venue=? AND base='BTC' AND symbol=? "
                          "AND ts_ms < ? ORDER BY ts_ms DESC LIMIT 1", (venue, symbol, start)).fetchall()
        rows = db.execute("SELECT ts_ms, rate, interval_h FROM snapshots WHERE venue=? AND base='BTC' AND symbol=? "
                          "AND ts_ms >= ? AND ts_ms <= ? ORDER BY ts_ms", (venue, symbol, start, now_ms)).fetchall()
        series.append(prev + rows)
    out, idx = [], [0] * len(series)
    for t in range(start - start % (step_s * 1000) + step_s * 1000, now_ms + 1, step_s * 1000):
        present = []
        for i, rows in enumerate(series):
            while idx[i] + 1 < len(rows) and rows[idx[i] + 1][0] <= t:
                idx[i] += 1
            if rows and rows[idx[i]][0] <= t and rows[idx[i]][2]:
                present.append(per_second_wad(rows[idx[i]][1], rows[idx[i]][2]))
        out.append((t, median_like_contract(present)))
    return out


def per_second_wad(rate, interval_h):
    """A rate per funding interval as a per-second fraction scaled 1e18 (positive = longs pay)."""
    return round(rate / (interval_h * 3600) * 10**18)


def venue_rates(db, now_ms, max_age_ms=MAX_DELAY_S * 1000):
    """Returns (rates in contract order with MISSING for unusable venues, observed_ms, detail)."""
    rates, observed, detail = [], [], {}
    for venue, symbol in VENUES:
        polled = db.execute("SELECT MAX(ts_ms) FROM polls WHERE venue=? AND ok=1", (venue,)).fetchone()[0]
        # venue AND base first: that is the recorder's index (snap_vb); without base it scans every row
        snap = db.execute("SELECT rate, interval_h FROM snapshots WHERE venue=? AND base='BTC' AND symbol=? "
                          "ORDER BY ts_ms DESC LIMIT 1", (venue, symbol)).fetchone()
        if polled is None or now_ms - polled > max_age_ms:
            why = "no recent successful poll"
        elif snap is None:
            why = "no snapshot for " + symbol
        elif not snap[1]:
            why = "unknown funding interval"
        else:
            rates.append(per_second_wad(snap[0], snap[1]))
            observed.append(polled)
            detail[venue] = {"rate_per_interval": snap[0], "interval_h": snap[1], "polled_ms": polled}
            continue
        rates.append(MISSING)
        detail[venue] = {"missing": why}
    return rates, (min(observed) if observed else None), detail


def post_if_needed(chain, feed, db, now_ms, min_age_s=180):
    """Post unless the feed was posted within `min_age_s`. 180 s leaves a trader at least two minutes to
    confirm the commit before the feed (stale after 300 s) would refuse it, and caps a flood of wake calls at
    one post per three minutes. Raises (never posts a partial or stale set) if fewer than three venues are fresh."""
    with _post_lock:
        last = chain.call(feed, "lastPostTime(uint8)", ["uint8"], [0], ["uint64"])[0]
        _, block_ts, _ = chain.block()
        if last and block_ts - last < min_age_s:
            return {"posted": False, "age_s": block_ts - last}
        rates, observed_ms, detail = venue_rates(db, now_ms)
        present = sum(r != MISSING for r in rates)
        if present < MIN_VENUES:
            raise RuntimeError(f"only {present} fresh venues, need {MIN_VENUES}: {detail}")
        observed_at = min(observed_ms // 1000, block_ts)  # never claim an observation from the future
        tx, receipt = chain.send(feed, "post(uint8,uint64,int256[5])", ["uint8", "uint64", "int256[5]"],
                                 [0, observed_at, rates], gas_factor=1.05)  # gas is the same every post
        return {"posted": True, "tx": tx, "gas_charged": int(receipt["gasUsed"], 16), "venues": detail,
                "observed_at": observed_at}
