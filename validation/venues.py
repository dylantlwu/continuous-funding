"""Public funding-rate history from Binance, OKX, Bybit and Hyperliquid.

Every adapter returns a sorted list of (settle_minute, rate) where settle_minute is Unix minutes
and rate is the fraction of notional paid by longs to shorts at that settlement (positive = longs pay).
Field names were checked against live responses on 2026-09-30.
"""
import time
from .http import get_json

MIN_MS = 60_000
VENUES = ("binance", "okx", "bybit", "hyperliquid", "bitget")


def symbol_for(venue, base):
    return {"binance": f"{base}USDT", "okx": f"{base}-USDT-SWAP", "bybit": f"{base}USDT", "hyperliquid": base, "bitget": f"{base}USDT"}[venue]


def _to_min(ms):
    # Binance sometimes stamps 00:00:00.001; round to the nearest minute
    return int(round(int(ms) / MIN_MS))


def _cacheable(end_ms):
    return end_ms < time.time() * 1000 - 2 * 3600 * 1000


def _dedupe_sorted(rows, start_ms, end_ms):
    """rows: (timestamp_ms, rate). Identical records from overlapping pages are removed by exact timestamp;
    distinct records that land in the same minute are SUMMED (e.g. Binance issues a 'Special' funding one
    second after the regular one; an earlier version silently kept only one of them)."""
    by_ms = {}
    for ms, r in rows:
        if start_ms <= int(ms) <= end_ms + MIN_MS:
            by_ms[int(ms)] = r
    out = {}
    for ms, r in by_ms.items():
        m = _to_min(ms)
        out[m] = out.get(m, 0.0) + r
    return sorted(out.items())


def binance_settled(base, start_ms, end_ms, split=False):
    """split=True returns (regular_rows, special_rows): 'Special' fundings are one-off charges that no
    premium-based forecast can anticipate (seen on NVDAUSDT 2026-09-10 00:00:01, -0.1117%)."""
    sym, rows, cur = symbol_for("binance", base), [], start_ms
    kinds = {}
    while cur < end_ms:
        page = get_json(f"https://fapi.binance.com/fapi/v1/fundingRate?symbol={sym}&startTime={cur}&endTime={end_ms}&limit=1000",
                        cache=_cacheable(end_ms))
        if not page:
            break
        rows += [(int(x["fundingTime"]), float(x["fundingRate"])) for x in page]
        kinds.update({int(x["fundingTime"]): x.get("rateType", "Regular") for x in page})
        cur = int(page[-1]["fundingTime"]) + 1
        if len(page) < 1000:
            break
    if not split:
        return _dedupe_sorted(rows, start_ms, end_ms)
    regular = _dedupe_sorted([(ms, r) for ms, r in rows if kinds.get(int(ms)) != "Special"], start_ms, end_ms)
    special = _dedupe_sorted([(ms, r) for ms, r in rows if kinds.get(int(ms)) == "Special"], start_ms, end_ms)
    return regular, special


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
        rows += [(int(x["fundingTime"]), float(x["realizedRate"] or x["fundingRate"])) for x in page]
        oldest = min(int(x["fundingTime"]) for x in page)
        if oldest <= start_ms or len(page) < 100:
            break
        after = oldest
    return _dedupe_sorted(rows, start_ms, end_ms)


def bybit_settled(base, start_ms, end_ms, symbol=None):
    sym, rows, end = symbol or symbol_for("bybit", base), [], end_ms
    while end > start_ms:
        res = get_json(f"https://api.bybit.com/v5/market/funding/history?category=linear&symbol={sym}&startTime={start_ms}&endTime={end}&limit=200",
                       cache=_cacheable(end))["result"]["list"]
        if not res:
            break
        rows += [(int(x["fundingRateTimestamp"]), float(x["fundingRate"])) for x in res]
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
        rows += [(int(x["time"]), float(x["fundingRate"])) for x in page]
        nxt = int(page[-1]["time"]) + 1
        if nxt <= cur:
            break
        cur = nxt
    return _dedupe_sorted(rows, start_ms, end_ms)


def bitget_settled(base, start_ms, end_ms, symbol=None):
    sym, rows, page = symbol or symbol_for("bitget", base), [], 1
    while page <= 50:
        d = get_json(f"https://api.bitget.com/api/v2/mix/market/history-fund-rate?symbol={sym}&productType=USDT-FUTURES&pageSize=100&pageNo={page}",
                     cache=False)
        if d.get("code") != "00000":
            raise RuntimeError(f"bitget {sym}: {d.get('msg')}")
        data = d["data"]
        if not data:
            break
        rows += [(int(x["fundingTime"]), float(x["fundingRate"])) for x in data]
        if min(int(x["fundingTime"]) for x in data) <= start_ms or len(data) < 100:
            break
        page += 1
    return _dedupe_sorted(rows, start_ms, end_ms)


SETTLED = {"binance": binance_settled, "okx": okx_settled, "bybit": bybit_settled, "hyperliquid": hyperliquid_settled,
           "bitget": bitget_settled}


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
