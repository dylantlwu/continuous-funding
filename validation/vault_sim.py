"""R2 vault simulation: which funding rule protects a vault that takes the other side of every trade?

    python3 -m validation.vault_sim --base BTC --days 30

Real inputs: hourly spot price (Binance klines) and the funding each venue actually charged
(true-up trackers over Binance, OKX, Bybit, Hyperliquid, Bitget settled history; consensus c = median).
Modelled inputs (assumptions, every one listed in the report and tunable below):
  * Directional crowd: exogenous net position D(t) in base units, under four scenarios. Baseline: the
    crowd ignores funding (worst case for the vault).
  * Arbitrageurs: each hour compare our rate with every venue's rate; if the best gap exceeds a cost
    threshold, hold a position on our venue (hedged on that venue) sized linearly up to a capacity.
    Their position adds to our net skew. Gross funding they collect = "arb extracted".
Vault = minus the net trader position. Vault PnL = funding it nets (rate x skew x price) + directional
(-skew x price change). Fees, slippage, liquidations and trader PnL feedback are ignored.
"""
import argparse
import datetime as dt
import math
import os
import random
import statistics
import time

from .http import get_json
from .run import fetch, venue_trackers

HOUR_MS = 3_600_000
APR = 24 * 365                      # hourly fraction x APR = annualised fraction

PARAMS = {
    "skew_scale": 100.0,            # base units; "full" imbalance for the skew-driven rules (≈ OI cap)
    "arb_capacity": 50.0,           # base units arbitrageurs will deploy at most
    "arb_threshold_apr": 0.03,      # gap below which arbitrage does not pay after costs; full size at 2x
    "cubic_k_apr": 0.25,            # LeverUp-style: rate = k * u^3 (their doc example: u=0.8 -> 12.8%)
    "velocity_apr_per_h": 0.02,     # SIP-279 / hybrid: rate moves this much per hour at full imbalance
    "velocity_cap_apr": 0.50,       # SIP-279-style cap
    "hybrid_band_apr": 0.10,        # hybrid: |p| <= w around consensus
    "seed": 7,
    # arbitrage model. "books" (default): one book per venue, can hold opposite sides at once, partial
    # adjustment, entry/exit hysteresis, costs, venue leg paid only at that venue's settlements.
    # "simple": the original single synthetic arbitrageur, all-in on the widest gap, reset every hour.
    "arb_model": "books",
    "fee_per_leg_bp": 3.0,          # between maker and taker on major venues
    "slippage_bp": 1.5,             # per entry or exit, small hedges on majors
    "hold_days": 14,                # funding arbitrage is typically held for weeks
    "exit_frac": 0.5,               # exit threshold = this x entry threshold (hysteresis)
    "adjust_per_h": 0.10,           # move 10% of the way to the target position each hour
    "ema_half_life_h": 24,          # expected funding = 24h EMA, filters true-up noise
}


def arb_thresholds(P):
    """Entry threshold (hourly fraction) = round-trip cost spread over the expected holding period."""
    round_trip = (4 * P["fee_per_leg_bp"] + 2 * P["slippage_bp"]) / 1e4
    entry = round_trip / (P["hold_days"] * 24)
    return entry, entry * P["exit_frac"], round_trip / 2          # per-side cost when entering or exiting


def venue_oi_shares(base):
    """Current open interest in base units on each venue, as shares. Used to split arbitrage capacity."""
    oi = {}
    try:
        oi["binance"] = float(get_json(f"https://fapi.binance.com/fapi/v1/openInterest?symbol={base}USDT")["openInterest"])
    except Exception:
        pass
    try:
        oi["bybit"] = float(get_json(f"https://api.bybit.com/v5/market/tickers?category=linear&symbol={base}USDT")["result"]["list"][0]["openInterest"])
    except Exception:
        pass
    try:
        oi["okx"] = float(get_json(f"https://www.okx.com/api/v5/public/open-interest?instType=SWAP&instId={base}-USDT-SWAP")["data"][0]["oiCcy"])
    except Exception:
        pass
    try:
        meta, ctx = get_json("https://api.hyperliquid.xyz/info", body={"type": "metaAndAssetCtxs"})
        oi["hyperliquid"] = float(ctx[[u["name"] for u in meta["universe"]].index(base)]["openInterest"])
    except Exception:
        pass
    try:
        oi["bitget"] = float([x for x in get_json("https://api.bitget.com/api/v2/mix/market/tickers?productType=USDT-FUTURES")["data"]
                              if x["symbol"] == f"{base}USDT"][0]["holdingAmount"])
    except Exception:
        pass
    tot = sum(oi.values())
    return {v: x / tot for v, x in oi.items()} if tot else {}


def hourly_venue_rates(per_venue):
    out = {}
    for v, inc in per_venue.items():
        tot, cnt = {}, {}
        for m, r in inc.items():
            h = m // 60
            tot[h] = tot.get(h, 0.0) + r
            cnt[h] = cnt.get(h, 0) + 1
        out[v] = {h: x for h, x in tot.items() if cnt[h] == 60}     # complete hours only
    return out


def spot_closes(base, start_h, end_h):
    out, cur = {}, start_h * HOUR_MS
    while cur < end_h * HOUR_MS:
        page = get_json(f"https://api.binance.com/api/v3/klines?symbol={base}USDT&interval=1h&startTime={cur}&limit=1000",
                        cache=(cur + 1000 * HOUR_MS) < time.time() * 1000 - 2 * HOUR_MS)
        if not page:
            break
        for k in page:
            out[int(k[0]) // HOUR_MS] = float(k[4])
        cur = int(page[-1][0]) + HOUR_MS
        if len(page) < 1000:
            break
    return out


def crowd_scenarios(prices, rng):
    n = len(prices)
    sc = {"persistent_long": [40.0] * n}
    rets = [0.0] * n
    for i in range(24, n):
        rets[i] = math.log(prices[i] / prices[i - 24])
    sd = statistics.pstdev(rets[24:]) or 1e-9
    sc["momentum"] = [max(-60.0, min(60.0, 30.0 * r / sd)) for r in rets]
    shock = []
    for i in range(n):
        if 240 <= i < 312:
            shock.append(60.0)
        elif 312 <= i < 384:
            shock.append(60.0 * (384 - i) / 72)
        else:
            shock.append(0.0)
    sc["shock"] = shock
    x, noise = 0.0, []
    for _ in range(n):
        x = 0.97 * x + rng.gauss(0.0, 4.0)
        noise.append(x)
    sc["noise"] = noise
    return sc


class Rule:
    def __init__(self, kind, P):
        self.kind, self.P, self.p = kind, P, 0.0

    def rate(self, skew, c):
        P = self.P
        u = max(-1.0, min(1.0, skew / P["skew_scale"]))
        if self.kind == "parity":
            return c
        if self.kind == "cubic":
            return math.copysign(P["cubic_k_apr"] * abs(u) ** 3, u) / APR
        if self.kind == "velocity":
            cap = P["velocity_cap_apr"] / APR
            self.p = max(-cap, min(cap, self.p + P["velocity_apr_per_h"] / APR * u))
            return self.p
        if self.kind == "hybrid":
            w = P["hybrid_band_apr"] / APR
            self.p = max(-w, min(w, self.p + P["velocity_apr_per_h"] / APR * u))
            return c + self.p
        raise ValueError(self.kind)


def simulate(hours, prices, cons, venue_h, crowd, kind, P, ctx=None):
    if P.get("arb_model", "simple") == "books":
        return simulate_books(hours, prices, cons, venue_h, crowd, kind, P, ctx or {})
    rule, skew = Rule(kind, P), 0.0
    out = {"fund": 0.0, "dir": 0.0, "arb": 0.0, "arb_net": 0.0, "crowd_paid": 0.0, "abs_skew": [], "dev": [], "rate": []}
    thr = P["arb_threshold_apr"] / APR
    for i, h in enumerate(hours[:-1]):
        r = rule.rate(skew, cons[i])                       # rate for this hour, set from last hour's skew
        best = max(venue_h, key=lambda v: abs(venue_h[v][h] - r))
        gap = venue_h[best][h] - r                          # >0: long us / short venue earns gap
        size = P["arb_capacity"] * max(0.0, min(1.0, (abs(gap) - thr) / thr)) if abs(gap) > thr else 0.0
        a = math.copysign(size, gap)
        skew = crowd[i] + a
        px, px_next = prices[i], prices[i + 1]
        out["fund"] += r * skew * px
        out["dir"] += -skew * (px_next - px)
        out["arb"] += a * gap * px
        out["arb_net"] += a * gap * px
        out["crowd_paid"] += r * crowd[i] * px
        out["abs_skew"].append(abs(skew))
        out["dev"].append(abs(r - cons[i]) * APR)
        out["rate"].append(r * APR)
    return out


def simulate_books(hours, prices, cons, venue_h, crowd, kind, P, ctx):
    """One arbitrage book per venue. Each hour: update 24h-EMA expectations of every venue's funding and of
    ours; each book moves part of the way toward a target sized by its expected gap net of costs (entry
    threshold when flat or reversing, lower exit threshold while holding). Our leg pays/receives our rate
    every hour; the venue leg is paid only at that venue's settlements (snapshot on the position held)."""
    rule, skew = Rule(kind, P), 0.0
    venues = list(venue_h)
    shares = ctx.get("shares") or {v: 1.0 / len(venues) for v in venues}
    settle = ctx.get("settle") or {}
    entry, exit_, side_cost = arb_thresholds(P)
    alpha = 1 - 0.5 ** (1.0 / P["ema_half_life_h"])
    books = {v: 0.0 for v in venues}
    ema_v = {v: venue_h[v][hours[0]] for v in venues}
    ema_ours = None
    out = {"fund": 0.0, "dir": 0.0, "arb": 0.0, "arb_net": 0.0, "crowd_paid": 0.0, "abs_skew": [], "dev": [], "rate": [],
           "fees": 0.0}
    for i, h in enumerate(hours[:-1]):
        px, px_next = prices[i], prices[i + 1]
        r = rule.rate(skew, cons[i])
        ema_ours = r if ema_ours is None else ema_ours + alpha * (r - ema_ours)
        for v in venues:
            ema_v[v] += alpha * (venue_h[v][h] - ema_v[v])
            if h in settle.get(v, {}):                                   # venue leg: snapshot payment
                out["arb"] += books[v] * settle[v][h] * px
        for v in venues:
            gap = ema_v[v] - ema_ours                                    # >0: long us / short v earns
            held = books[v]
            same_side = held != 0 and math.copysign(1, held) == math.copysign(1, gap)
            thr = exit_ if same_side else entry
            if held != 0 and not same_side:
                target = 0.0                                             # close before reversing
            else:
                size = P["arb_capacity"] * shares.get(v, 0.0) * max(0.0, min(1.0, (abs(gap) - thr) / entry))
                target = math.copysign(size, gap)
            new = held + P["adjust_per_h"] * (target - held)
            cap_v = P["arb_capacity"] * shares.get(v, 0.0)
            if target == 0.0 and abs(new) < 0.02 * max(cap_v, 1e-12):
                new = 0.0                                                # fully closed: free to reverse next hour
            out["fees"] += abs(new - held) * px * side_cost
            books[v] = new
        net_arb = sum(books.values())
        skew = crowd[i] + net_arb
        out["arb"] += -net_arb * r * px                                  # our leg
        out["fund"] += r * skew * px
        out["dir"] += -skew * (px_next - px)
        out["crowd_paid"] += r * crowd[i] * px
        out["abs_skew"].append(abs(skew))
        out["dev"].append(abs(r - cons[i]) * APR)
        out["rate"].append(r * APR)
    out["arb_net"] = out["arb"] - out["fees"]
    out["books"] = dict(books)
    return out


def bootstrap_paths(prices, n_paths, block, rng):
    """Block-bootstrap hourly log returns (24h blocks) after removing their mean, so price direction
    averages out across paths. Funding paths stay historical (assumes funding independent of the path)."""
    rets = [math.log(prices[i + 1] / prices[i]) for i in range(len(prices) - 1)]
    mu = statistics.mean(rets)
    rets = [r - mu for r in rets]
    n = len(prices)
    paths = []
    for _ in range(n_paths):
        out, px = [prices[0]], prices[0]
        while len(out) < n:
            j = rng.randrange(0, len(rets) - block)
            for r in rets[j:j + block]:
                if len(out) >= n:
                    break
                px *= math.exp(r)
                out.append(px)
        paths.append(out)
    return paths


def monte_carlo(hours, prices, cons, vh, P, n_paths, ctx=None):
    rng = random.Random(P["seed"])
    rules = ["parity", "cubic", "velocity", "hybrid"]
    res = {}
    for path in bootstrap_paths(prices, n_paths, 24, rng):
        crowd = crowd_scenarios(path, random.Random(rng.random()))
        for scn, cp in crowd.items():
            for k in rules:
                o = simulate(hours, path, cons, vh, cp, k, P, ctx)
                r = res.setdefault((scn, k), {"total": [], "fund": [], "skew": [], "arb": [], "arb_net": []})
                r["total"].append(o["fund"] + o["dir"])
                r["fund"].append(o["fund"])
                r["skew"].append(statistics.mean(o["abs_skew"]))
                r["arb"].append(o["arb"])
                r["arb_net"].append(o["arb_net"])
    return res


def band_sweep(hours, prices, cons, vh, P, n_paths, caps, widths, scenarios=("persistent_long", "momentum"), ctx=None):
    """Hybrid rule only: vault risk vs deviation from market across band widths w and arbitrage capacities."""
    paths = bootstrap_paths(prices, n_paths, 24, random.Random(P["seed"]))
    rows = []
    for cap in caps:
        for w in widths:
            Q = dict(P, hybrid_band_apr=w, arb_capacity=cap)
            for scn in scenarios:
                rng = random.Random(11)
                tot, skew, gap, arb = [], [], [], []
                for path in paths:
                    o = simulate(hours, path, cons, vh, crowd_scenarios(path, random.Random(rng.random()))[scn], "hybrid", Q, ctx)
                    tot.append(o["fund"] + o["dir"])
                    skew.append(statistics.mean(o["abs_skew"]))
                    gap.append(statistics.mean(o["dev"]))
                    arb.append(o["arb_net"])
                t = sorted(tot)
                rows.append(f"| {cap:.0f} | {100*w:.0f}% | {scn} | {statistics.pstdev(t):,.0f} | {t[int(0.05*(len(t)-1))]:+,.0f} | "
                            f"{statistics.mean(skew):.1f} | {100*statistics.mean(gap):.2f} | {statistics.mean(arb):+,.0f} |")
    return ["| arb capacity | w | scenario | std of vault total $ | 5th pct $ | mean abs skew | mean abs gap to c (APR %) | mean arb net of costs $ |",
            "|---|---|---|---|---|---|---|---|"] + rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="BTC")
    ap.add_argument("--days", type=int, default=30)
    ap.add_argument("--paths", type=int, default=0, help="Monte Carlo price paths (0 = historical path only)")
    ap.add_argument("--sweep", action="store_true", help="also sweep the hybrid band w and arbitrage capacity (uses --paths, default 100)")
    ap.add_argument("--arb-model", choices=("books", "simple"), default=PARAMS["arb_model"])
    args = ap.parse_args()
    P = dict(PARAMS, arb_model=args.arb_model)
    end = int(time.time() * 1000)
    start = end - args.days * 86_400_000
    settled, missing = fetch(args.base, start, end)
    per_venue, notes = venue_trackers(args.base, settled)
    vh = hourly_venue_rates(per_venue)
    common = sorted(set.intersection(*(set(x) for x in vh.values())))
    px = spot_closes(args.base, common[0], common[-1] + 1)
    hours = [h for h in common if h in px]
    if len(hours) < 24 * 7:
        raise RuntimeError(f"only {len(hours)} usable hours")
    prices = [px[h] for h in hours]
    cons = [statistics.median(vh[v][h] for v in vh) for h in hours]
    crowd = crowd_scenarios(prices, random.Random(P["seed"]))
    shares = venue_oi_shares(args.base)
    if set(shares) != set(vh):
        notes.append(f"open interest unavailable for {sorted(set(vh) - set(shares))}: those venues get no arbitrage capacity")
    ctx = {"shares": shares,
           "settle": {v: {m // 60: r for m, r in settled[v]} for v in vh}}
    entry, exit_, side_cost = arb_thresholds(P)
    rules = ["parity", "cubic", "velocity", "hybrid"]
    names = {"parity": "pure parity (rate = c)", "cubic": "LeverUp-style cubic (no c)",
             "velocity": "SIP-279-style velocity (no c)", "hybrid": "hybrid (rate = c + p, |p| <= w)"}
    L = [f"# R2 vault simulation · {args.base}",
         f"generated {dt.datetime.utcnow():%Y-%m-%d %H:%M} UTC · {len(hours)} hours · {dt.datetime.utcfromtimestamp(hours[0]*3600):%Y-%m-%d %H:%M} → {dt.datetime.utcfromtimestamp(hours[-1]*3600):%Y-%m-%d %H:%M} UTC",
         f"price {prices[0]:,.0f} → {prices[-1]:,.0f} ({100*(prices[-1]/prices[0]-1):+.1f}%), venues: {', '.join(vh)}" + (f"; skipped: {', '.join(missing)}" if missing else ""),
         f"consensus c (median of venues): mean {100*statistics.mean(cons)*APR:+.2f}% APR", "",
         "Assumptions: " + ", ".join(f"{k}={v}" for k, v in P.items()) + ". Crowd ignores funding (worst case). Vault fees, liquidations ignored. Base units; USD = base x hourly spot close.",
         (f"Arbitrage model 'books': entry threshold {100*entry*APR:.2f}% APR, exit {100*exit_*APR:.2f}% APR, cost per entry or exit {1e4*side_cost:.1f} bp; "
          "capacity split by current open interest: " + ", ".join(f"{v} {100*x:.1f}%" for v, x in sorted(shares.items(), key=lambda kv: -kv[1])))
         if P["arb_model"] == "books" else "Arbitrage model 'simple': one synthetic arbitrageur, all-in on the widest gap, reset hourly, no costs.",
         ""] + [f"- note: {n}" for n in notes] + [""]
    summary = {}
    for scn, crowd_path in crowd.items():
        L += [f"## Scenario: {scn}", "",
              "| rule | vault funding $ | vault directional $ | **vault total $** | arb gross $ | arb net of costs $ | crowd paid $ | mean abs skew | max abs skew | mean abs gap to c (APR %) |",
              "|---|---|---|---|---|---|---|---|---|---|"]
        for k in rules:
            o = simulate(hours, prices, cons, vh, crowd_path, k, P, ctx)
            summary[(scn, k)] = o
            L.append(f"| {names[k]} | {o['fund']:+,.0f} | {o['dir']:+,.0f} | **{o['fund']+o['dir']:+,.0f}** | {o['arb']:+,.0f} | {o['arb_net']:+,.0f} | {o['crowd_paid']:+,.0f} | "
                     f"{statistics.mean(o['abs_skew']):.1f} | {max(o['abs_skew']):.1f} | {100*statistics.mean(o['dev']):.2f} |")
        L.append("")
    if args.paths:
        mc = monte_carlo(hours, prices, cons, vh, P, args.paths, ctx)
        L += [f"## Monte Carlo: {args.paths} block-bootstrapped price paths (24h blocks, mean return removed)", "",
              "| scenario | rule | mean vault total $ | std $ | 5th pct $ | mean vault funding $ | mean abs skew | mean arb net of costs $ |",
              "|---|---|---|---|---|---|---|---|"]
        for scn in crowd:
            for k in rules:
                r = mc[(scn, k)]
                t = sorted(r["total"])
                L.append(f"| {scn} | {names[k]} | {statistics.mean(t):+,.0f} | {statistics.pstdev(t):,.0f} | {t[int(0.05*(len(t)-1))]:+,.0f} | "
                         f"{statistics.mean(r['fund']):+,.0f} | {statistics.mean(r['skew']):.1f} | {statistics.mean(r['arb_net']):+,.0f} |")
        L.append("")
    if args.sweep:
        L += [f"## Band sweep (hybrid only): {args.paths or 100} paths", ""]
        L += band_sweep(hours, prices, cons, vh, P, args.paths or 100, (20.0, 50.0, 100.0), (0.0, 0.02, 0.05, 0.10, 0.20), ctx=ctx)
        L.append("")
    out = "\n".join(L)
    print(out)
    rep = os.path.join(os.path.dirname(__file__), "reports")
    os.makedirs(rep, exist_ok=True)
    path = os.path.join(rep, f"{dt.datetime.utcnow():%Y%m%d-%H%M}-vault-sim-{args.base}.md")
    with open(path, "w") as f:
        f.write(out + "\n")
    print(f"\nreport written: {path}")


if __name__ == "__main__":
    main()
