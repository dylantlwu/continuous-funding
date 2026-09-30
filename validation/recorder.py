"""Live recorder: every venue's CURRENT predicted funding rate, every minute.

History APIs only give settled rates; to validate the tracker on real intraperiod predictions (and to see how
much each venue revises its prediction near settlement) we must record them as they happen.

    nohup python3 -m validation.recorder --every 60 >> validation/data/recorder.log 2>&1 &

Storage: $RECORDER_DB, default validation/data/live.sqlite (gitignored). On Railway: /data/live.sqlite on a volume.
  polls(ts_ms, venue, ok, rows, latency_ms, error)       one row per venue per round: tells "no change" from "no data"
  snapshots(ts_ms, venue, base, symbol, rate, next_ms, interval_h)   written only when rate or next settlement changes
Fields checked against live responses on 2026-09-30. Binance lastFundingRate equals Hyperliquid's 'BinPerp'
predicted value, confirming it is the live prediction, not the last settled rate.
"""
import argparse
import concurrent.futures as cf
import os
import sqlite3
import sys
import time

from .http import get_json
from .perp_only_study import underlying

DB = os.environ.get("RECORDER_DB") or os.path.join(os.path.dirname(__file__), "data", "live.sqlite")


def _binance(state):
    if time.time() - state.get("bn_info_at", 0) > 600:
        state["bn_int"] = {x["symbol"]: float(x["fundingIntervalHours"]) for x in get_json("https://fapi.binance.com/fapi/v1/fundingInfo")}
        state["bn_info_at"] = time.time()
    out = []
    for x in get_json("https://fapi.binance.com/fapi/v1/premiumIndex"):
        s = x["symbol"]
        if s.endswith("USDT") and x.get("nextFundingTime"):
            out.append((underlying(s[:-4]), s, float(x["lastFundingRate"]), int(x["nextFundingTime"]), state["bn_int"].get(s, 8.0)))
    return out


def _bybit(state):
    out = []
    for x in get_json("https://api.bybit.com/v5/market/tickers?category=linear")["result"]["list"]:
        s = x["symbol"]
        if s.endswith("USDT") and x.get("fundingRate") not in (None, "") and x.get("nextFundingTime") not in (None, "", "0"):
            out.append((underlying(s[:-4]), s, float(x["fundingRate"]), int(x["nextFundingTime"]), float(x.get("fundingIntervalHour") or 8)))
    return out


def _okx(state):
    out = []
    for x in get_json("https://www.okx.com/api/v5/public/funding-rate?instId=ANY")["data"]:
        s = x["instId"]
        if s.endswith("-USDT-SWAP") and x.get("fundingRate"):
            nxt, after = int(x["fundingTime"]), int(x.get("nextFundingTime") or 0)
            out.append((underlying(s[:-10]), s, float(x["fundingRate"]), nxt, (after - nxt) / 3.6e6 if after > nxt else None))
    return out


def _bitget(state):
    d = get_json("https://api.bitget.com/api/v2/mix/market/current-fund-rate?productType=USDT-FUTURES")
    if d.get("code") != "00000":
        raise RuntimeError(d.get("msg"))
    return [(underlying(x["symbol"][:-4]), x["symbol"], float(x["fundingRate"]), int(x["nextUpdate"]), float(x["fundingRateInterval"]))
            for x in d["data"] if x["symbol"].endswith("USDT")]


def _hyperliquid(state):
    out = []
    for coin, views in get_json("https://api.hyperliquid.xyz/info", body={"type": "predictedFundings"}):
        v = dict(views).get("HlPerp")
        if v:
            out.append((underlying(coin), coin, float(v["fundingRate"]), int(v["nextFundingTime"]), float(v["fundingIntervalHours"])))
    return out


SOURCES = {"binance": _binance, "bybit": _bybit, "okx": _okx, "bitget": _bitget, "hyperliquid": _hyperliquid}


def open_db(path=DB):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    db = sqlite3.connect(path)
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("CREATE TABLE IF NOT EXISTS polls(ts_ms INTEGER, venue TEXT, ok INTEGER, rows INTEGER, latency_ms INTEGER, error TEXT)")
    db.execute("CREATE TABLE IF NOT EXISTS snapshots(ts_ms INTEGER, venue TEXT, base TEXT, symbol TEXT, rate REAL, next_ms INTEGER, interval_h REAL)")
    db.execute("CREATE INDEX IF NOT EXISTS snap_vb ON snapshots(venue, base, ts_ms)")
    return db


def one_round(db, last, state):
    started = int(time.time() * 1000)

    def run(v):
        t = time.time()
        try:
            return v, SOURCES[v](state), None, int((time.time() - t) * 1000)
        except Exception as e:  # one venue failing must not stop the others; it is recorded, not hidden
            return v, None, str(e)[:300], int((time.time() - t) * 1000)

    with cf.ThreadPoolExecutor(max_workers=len(SOURCES)) as ex:
        results = list(ex.map(run, SOURCES))
    changed = 0
    for v, rows, err, lat in results:
        db.execute("INSERT INTO polls VALUES (?,?,?,?,?,?)", (started, v, int(err is None), len(rows or []), lat, err))
        for base, sym, rate, nxt, ih in rows or []:
            key = (v, sym)
            if last.get(key) != (rate, nxt):
                db.execute("INSERT INTO snapshots VALUES (?,?,?,?,?,?,?)", (started, v, base, sym, rate, nxt, ih))
                last[key] = (rate, nxt)
                changed += 1
    db.commit()
    return results, changed


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--every", type=int, default=60, help="seconds between rounds")
    ap.add_argument("--rounds", type=int, default=0, help="0 = forever")
    args = ap.parse_args()
    db, last, state, n = open_db(), {}, {}, 0
    print(f"recorder started pid={os.getpid()} db={DB}", flush=True)
    while True:
        t = time.time()
        results, changed = one_round(db, last, state)
        n += 1
        summary = " ".join(f"{v}:{'ok' if e is None else 'ERR'}({len(r or [])},{lat}ms)" for v, r, e, lat in results)
        print(f"{time.strftime('%Y-%m-%d %H:%M:%S')} round {n} changed={changed} {summary}", flush=True)
        if args.rounds and n >= args.rounds:
            break
        time.sleep(max(0.0, args.every - (time.time() - t)))


if __name__ == "__main__":
    main()
