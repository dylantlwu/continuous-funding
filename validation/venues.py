"""Public funding-rate history from Binance, OKX, Bybit and Hyperliquid.

Every adapter returns a sorted list of (settle_minute, rate) where settle_minute is Unix minutes
and rate is the fraction of notional paid by longs to shorts at that settlement (positive = longs pay).
Field names were checked against live responses on 2026-09-30.
"""
import time
from .http import get_json

MIN_MS = 60_000
VENUES = ("binance", "okx", "bybit", "hyperliquid")


def symbol_for(venue, base):
    return {"binance": f"{base}USDT", "okx": f"{base}-USDT-SWAP", "bybit": f"{base}USDT", "hyperliquid": base}[venue]


def _to_min(ms):
    # Binance sometimes stamps 00:00:00.001; round to the nearest minute
    return int(round(int(ms) / MIN_MS))


def _cacheable(end_ms):
    return end_ms < time.time() * 1000 - 2 * 3600 * 1000


def _dedupe_sorted(rows, start_ms, end_ms):
    lo, hi = _to_min(start_ms), _to_min(end_ms)
    out = {}
    for m, r in rows:
        if lo <= m <= hi:
            out[m] = r
    return sorted(out.items())


def binance_settled(base, start_ms, end_ms):
    sym, rows, cur = symbol_for("binance", base), [], start_ms
    while cur < end_ms:
        page = get_json(f"https://fapi.binance.com/fapi/v1/fundingRate?symbol={sym}&startTime={cur}&endTime={end_ms}&limit=1000",
                        cache=_cacheable(end_ms))
        if not page:
            break
        rows += [(_to_min(x["fundingTime"]), float(x["fundingRate"])) for x in page]
        cur = int(page[-1]["fundingTime"]) + 1
        if len(page) < 1000:
            break
    return _dedupe_sorted(rows, start_ms, end_ms)


def binance_premium_1m(base, start_ms, end_ms):
    """Per-minute premium index (kline close). Returns {minute: premium}."""
    sym, out, cur = symbol_for("binance", base), {}, start_ms
    while cur < end_ms:
        page_end = min(cur + 1500 * MIN_MS - 1, end_ms)
        page = get_json(f"https://fapi.binance.com/fapi/v1/premiumIndexKlines?symbol={sym}&interval=1m&startTime={cur}&endTime={page_end}&limit=1500",
                        cache=_cacheable(page_end))
        for k in page:
            out[_to_min(k[0])] = float(k[4])
        cur = page_end + 1
    return out


def okx_settled(base, start_ms, end_ms):
    inst, rows, after = symbol_for("okx", base), [], end_ms + 1
    while True:
        page = get_json(f"https://www.okx.com/api/v5/public/funding-rate-history?instId={inst}&after={after}&limit=100",
                        cache=_cacheable(after))["data"]
        if not page:
            break
        rows += [(_to_min(x["fundingTime"]), float(x["realizedRate"] or x["fundingRate"])) for x in page]
        oldest = min(int(x["fundingTime"]) for x in page)
        if oldest <= start_ms or len(page) < 100:
            break
        after = oldest
    return _dedupe_sorted(rows, start_ms, end_ms)


def bybit_settled(base, start_ms, end_ms):
    sym, rows, end = symbol_for("bybit", base), [], end_ms
    while end > start_ms:
        res = get_json(f"https://api.bybit.com/v5/market/funding/history?category=linear&symbol={sym}&startTime={start_ms}&endTime={end}&limit=200",
                       cache=_cacheable(end))["result"]["list"]
        if not res:
            break
        rows += [(_to_min(x["fundingRateTimestamp"]), float(x["fundingRate"])) for x in res]
        oldest = min(int(x["fundingRateTimestamp"]) for x in res)
        if len(res) < 200:
            break
        end = oldest - 1
    return _dedupe_sorted(rows, start_ms, end_ms)


def hyperliquid_settled(base, start_ms, end_ms):
    rows, cur = [], start_ms
    while cur < end_ms:
        page = get_json("https://api.hyperliquid.xyz/info",
                        body={"type": "fundingHistory", "coin": symbol_for("hyperliquid", base), "startTime": cur, "endTime": end_ms},
                        cache=_cacheable(end_ms))
        if not page:
            break
        rows += [(_to_min(x["time"]), float(x["fundingRate"])) for x in page]
        nxt = int(page[-1]["time"]) + 1
        if nxt <= cur:
            break
        cur = nxt
    return _dedupe_sorted(rows, start_ms, end_ms)


SETTLED = {"binance": binance_settled, "okx": okx_settled, "bybit": bybit_settled, "hyperliquid": hyperliquid_settled}


def binance_params(base):
    """Per-symbol interest rate (per 8h) and funding cap from Binance. Stock perps use interest 0 (checked 2026-09-30).
    These are current values; history of changes is not published, so a change inside the window is a known limitation."""
    sym = symbol_for("binance", base)
    pi = get_json(f"https://fapi.binance.com/fapi/v1/premiumIndex?symbol={sym}")
    cap = None
    for x in get_json("https://fapi.binance.com/fapi/v1/fundingInfo"):
        if x["symbol"] == sym:
            cap = float(x["adjustedFundingRateCap"])
    return float(pi["interestRate"]), cap
