"""Does a perp with no spot market on the same venue pay systematically higher funding?

Natural experiment (owner's hypothesis, 2026-09-30): compare Bybit and Bitget on the same underlying.
  treatment: Bybit has the perp but NO spot; Bitget has both      -> expect Bybit funding higher
  control:   both venues have perp and spot                        -> expect ~no difference
  reverse:   Bybit has both; Bitget has the perp but NO spot        -> expect Bitget higher (sign flips)
Funding is summed over the common window and annualised, so 1h/4h/8h settlement intervals do not matter.

    python3 -m validation.perp_only_study --days 30 --control 80
"""
import argparse
import concurrent.futures as cf
import sys
import datetime as dt
import os
import re
import statistics
import time

from .http import get_json
from .venues import bitget_settled, bybit_settled

PREFIX = re.compile(r"^(10{3,})([A-Z].*)$")    # 1000PEPE -> PEPE
SUFFIX = re.compile(r"^([A-Z].*?)(10{3,})$")    # SHIB1000 -> SHIB


def underlying(base):
    b = base.upper()
    m = PREFIX.match(b) or None
    if m:
        return m.group(2)
    m = SUFFIX.match(b)
    return m.group(1) if m else b


def universe():
    by_perp, by_spot, bg_perp, bg_spot, bg_vol = {}, set(), {}, set(), {}
    for x in get_json("https://api.bybit.com/v5/market/instruments-info?category=linear&limit=1000")["result"]["list"]:
        if x["contractType"] == "LinearPerpetual" and x["status"] == "Trading" and x["settleCoin"] == "USDT" and not x.get("isPreListing"):
            u = underlying(x["baseCoin"])
            if u not in by_perp or len(x["symbol"]) < len(by_perp[u]):
                by_perp[u] = x["symbol"]
    for x in get_json("https://api.bybit.com/v5/market/instruments-info?category=spot&limit=1000")["result"]["list"]:
        if x["status"] == "Trading":
            by_spot.add(underlying(x["baseCoin"]))
    for x in get_json("https://api.bitget.com/api/v2/mix/market/contracts?productType=USDT-FUTURES")["data"]:
        if x["symbolType"] == "perpetual" and x["symbolStatus"] == "normal":
            u = underlying(x["baseCoin"])
            if u not in bg_perp or len(x["symbol"]) < len(bg_perp[u]):
                bg_perp[u] = x["symbol"]
    for x in get_json("https://api.bitget.com/api/v2/spot/public/symbols")["data"]:
        if x["status"] == "online":
            bg_spot.add(underlying(x["baseCoin"]))
    for x in get_json("https://api.bitget.com/api/v2/mix/market/tickers?productType=USDT-FUTURES")["data"]:
        bg_vol[x["symbol"]] = float(x.get("usdtVolume") or 0)
    both = set(by_perp) & set(bg_perp)
    groups = {
        "treatment (Bybit no spot, Bitget spot)": sorted(u for u in both if u not in by_spot and u in bg_spot),
        "control (both have spot)": sorted(u for u in both if u in by_spot and u in bg_spot),
        "reverse (Bybit spot, Bitget no spot)": sorted(u for u in both if u in by_spot and u not in bg_spot),
    }
    return groups, by_perp, bg_perp, bg_vol


def apr_pair(u, by_sym, bg_sym, start, end, min_days):
    by = bybit_settled(None, start, end, symbol=by_sym)
    bg = bitget_settled(None, start, end, symbol=bg_sym)
    if len(by) < 3 or len(bg) < 3:
        return None
    lo, hi = max(by[0][0], bg[0][0]), min(by[-1][0], bg[-1][0])
    days = (hi - lo) / 1440
    if days < min_days:
        return None
    s_by = sum(r for m, r in by if lo < m <= hi)
    s_bg = sum(r for m, r in bg if lo < m <= hi)
    return {"u": u, "days": days, "bybit_apr": 100 * s_by * 365 / days, "bitget_apr": 100 * s_bg * 365 / days,
            "by_int_h": round((by[-1][0] - by[0][0]) / max(len(by) - 1, 1) / 60, 1),
            "bg_int_h": round((bg[-1][0] - bg[0][0]) / max(len(bg) - 1, 1) / 60, 1)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--days", type=int, default=30)
    ap.add_argument("--min-days", type=float, default=7)
    ap.add_argument("--control", type=int, default=80, help="control group size (top Bitget volume)")
    args = ap.parse_args()
    end = int(time.time() * 1000)
    start = end - args.days * 86_400_000
    groups, by_perp, bg_perp, bg_vol = universe()
    ctrl_key = "control (both have spot)"
    groups[ctrl_key] = sorted(groups[ctrl_key], key=lambda u: -bg_vol.get(bg_perp[u], 0))[: args.control]
    lines = ["# Perp-only vs perp+spot funding: Bybit vs Bitget natural experiment",
             f"generated {dt.datetime.utcnow():%Y-%m-%d %H:%M} UTC · last {args.days} days · common window per coin ≥ {args.min_days} days · funding APR = sum of settled rates annualised", ""]
    results, errors = {}, []
    for g, us in groups.items():
        res = []
        with cf.ThreadPoolExecutor(max_workers=8) as ex:
            futs = {ex.submit(apr_pair, u, by_perp[u], bg_perp[u], start, end, args.min_days): u for u in us}
            for i, f in enumerate(cf.as_completed(futs), 1):
                try:
                    r = f.result()
                    if r:
                        res.append(r)
                except Exception as e:
                    errors.append(f"{futs[f]}: {str(e)[:100]}")
                if i % 20 == 0 or i == len(us):
                    print(f"  {g}: {i}/{len(us)}", file=sys.stderr, flush=True)
        results[g] = res
    lines += ["| group | coins in group | coins measured | median Bybit − Bitget (APR pts) | mean | share Bybit higher | median funding level (avg of both, APR %) | median Bitget 24h volume (USDT) |", "|---|---|---|---|---|---|---|---|"]
    for g, res in results.items():
        diffs = [r["bybit_apr"] - r["bitget_apr"] for r in res]
        if diffs:
            level = statistics.median([(r["bybit_apr"] + r["bitget_apr"]) / 2 for r in res])
            vol = statistics.median([bg_vol.get(bg_perp[r["u"]], 0) for r in res])
            lines.append(f"| {g} | {len(groups[g])} | {len(res)} | {statistics.median(diffs):+.2f} | {statistics.mean(diffs):+.2f} | {100*sum(d>0 for d in diffs)/len(diffs):.0f}% | {level:+.2f} | {vol:,.0f} |")
        else:
            lines.append(f"| {g} | {len(groups[g])} | 0 | – | – | – | – | – |")
    # volume-matched comparison: control coins restricted to the treatment group's volume range
    tr = results.get("treatment (Bybit no spot, Bitget spot)", [])
    ct = results.get("control (both have spot)", [])
    if tr and ct:
        tv = sorted(bg_vol.get(bg_perp[r["u"]], 0) for r in tr)
        lo_v, hi_v = tv[len(tv) // 10], tv[(9 * len(tv)) // 10]
        m = [r for r in ct if lo_v <= bg_vol.get(bg_perp[r["u"]], 0) <= hi_v]
        if m:
            d = [r["bybit_apr"] - r["bitget_apr"] for r in m]
            lines.append(f"| control, volume-matched to treatment (10th–90th pct: {lo_v:,.0f}–{hi_v:,.0f}) | – | {len(m)} | {statistics.median(d):+.2f} | {statistics.mean(d):+.2f} | {100*sum(x>0 for x in d)/len(d):.0f}% | – | – |")
    for g, res in results.items():
        lines += ["", f"## {g}: largest gaps", "", "| coin | days | Bybit APR % | Bitget APR % | gap | Bybit interval h | Bitget interval h |", "|---|---|---|---|---|---|---|"]
        for r in sorted(res, key=lambda r: -abs(r["bybit_apr"] - r["bitget_apr"]))[:15]:
            lines.append(f"| {r['u']} | {r['days']:.1f} | {r['bybit_apr']:+.1f} | {r['bitget_apr']:+.1f} | {r['bybit_apr']-r['bitget_apr']:+.1f} | {r['by_int_h']} | {r['bg_int_h']} |")
    if errors:
        lines += ["", f"## skipped with errors ({len(errors)})", ""] + [f"- {e}" for e in errors[:40]]
    out = "\n".join(lines)
    print(out)
    rep = os.path.join(os.path.dirname(__file__), "reports")
    os.makedirs(rep, exist_ok=True)
    path = os.path.join(rep, f"{dt.datetime.utcnow():%Y%m%d-%H%M}-perp-only-study.md")
    with open(path, "w") as f:
        f.write(out + "\n")
    print(f"\nreport written: {path}")


if __name__ == "__main__":
    main()
