"""Validation engine CLI.

    python3 -m validation.run --bases BTC,ETH,SOL --days 30
    python3 -m validation.run --bases BTC:binance,XYZ:bybit --start 2026-08-01 --end 2026-09-01

For each base asset: pull settled funding from Binance, OKX, Bybit, Hyperliquid (venues that do not list it are
reported and skipped); build our charge under several policies; score how much funding an arbitrageur could extract
against each policy by hedging on each venue. Objective (owner, 2026-09-30): leave the least to extract.
"""
import argparse
import datetime as dt
import os
import time

from . import arb, binance_recon, tracker
from .venues import SETTLED, VENUES, binance_params, binance_premium_1m, binance_settled

DAY_MS = 86_400_000
BOUNDARY = 480  # minutes; 00/08/16 UTC settle on every venue we use, so windows cut here have no partial periods


def fetch(base, start, end):
    settled, missing = {}, {}
    for v in VENUES:
        try:
            rows = SETTLED[v](base, start, end)
            if len(rows) < 3:
                missing[v] = f"only {len(rows)} settlements"
            else:
                settled[v] = rows
        except Exception as e:  # not listed, delisted, or API refused: report, never silently use partial data
            missing[v] = str(e)[:120]
    return settled, missing


def build_policies(base, settled, anchor):
    notes, per_venue = [], {}
    for v, rows in settled.items():
        if v == "binance":
            prem = binance_premium_1m(base, rows[0][0] * 60_000, rows[-1][0] * 60_000)
            interest, cap = binance_params(base)
            regular, special = binance_settled(base, rows[0][0] * 60_000, rows[-1][0] * 60_000, split=True)
            # forecast quality is judged on regular settlements only; specials are listed, then charged via true-up
            r = binance_recon.validate(binance_recon.build_periods(regular, prem, interest_8h=interest, cap=cap))
            for m, rate in special:
                notes.append(f"**Binance Special funding** at minute {m} ({dt.datetime.utcfromtimestamp(m*60):%Y-%m-%d %H:%M} UTC): {rate:+.6f}; not forecastable, recovered by true-up")
            periods = binance_recon.build_periods(rows, prem, interest_8h=interest, cap=cap)
            if any(not p.get("pred") for p in periods):
                raise RuntimeError(f"{base}: Binance periods without premium data")
            notes.append(f"Binance live-prediction rebuild vs settlement (interest {interest:.4%}/8h, cap {cap}): {r['periods']} periods, mean |err| {r['mean_abs_bp']:.3f} bp, max {r['max_abs_bp']:.3f} bp")
            per_venue[v] = tracker.track(periods)
        else:
            per_venue[v] = tracker.track(tracker.lagged_periods(rows))
    pols = {}
    if anchor not in per_venue:
        notes.append(f"**anchor {anchor} does not list {base}; anchor policy skipped**")
    else:
        pols[f"anchor_{anchor}"] = per_venue[anchor]
        if anchor == "binance":
            pols["anchor_binance_lagged"] = tracker.track(tracker.lagged_periods(settled["binance"]))
        else:
            notes.append(f"anchor {anchor}: only settled history is available, so its tracker uses last-settled as the prediction")
    if len(per_venue) >= 3:
        pols[f"median_{len(per_venue)}"] = tracker.combine(per_venue, "median")
    if len(per_venue) >= 2:
        pols[f"midrange_{len(per_venue)}"] = tracker.combine(per_venue, "midrange")
    return pols, notes


def floor_apr(settled):
    """Smallest worst-case persistent arbitrage any single charge path can achieve: half the spread between the
    highest- and lowest-paying venue over a common window."""
    lo = max(rows[0][0] for rows in settled.values())
    hi = min(rows[-1][0] for rows in settled.values())
    lo, hi = -(-lo // BOUNDARY) * BOUNDARY, (hi // BOUNDARY) * BOUNDARY
    days = (hi - lo) / 1440
    totals = {v: sum(r for m, r in rows if lo < m <= hi) for v, rows in settled.items()}
    aprs = {v: 100 * t * 365 / days for v, t in totals.items()}
    return (max(aprs.values()) - min(aprs.values())) / 2, aprs, days


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bases", default="BTC,ETH,SOL", help="comma list; BASE or BASE:anchor (default anchor binance)")
    ap.add_argument("--days", type=int, default=30)
    ap.add_argument("--start", help="YYYY-MM-DD (UTC), overrides --days")
    ap.add_argument("--end", help="YYYY-MM-DD (UTC)")
    args = ap.parse_args()
    end = int(dt.datetime.strptime(args.end, "%Y-%m-%d").replace(tzinfo=dt.timezone.utc).timestamp() * 1000) if args.end else int(time.time() * 1000)
    start = int(dt.datetime.strptime(args.start, "%Y-%m-%d").replace(tzinfo=dt.timezone.utc).timestamp() * 1000) if args.start else end - args.days * DAY_MS
    lines = ["# Funding arbitrage extractable against each charging policy",
             f"generated {dt.datetime.utcnow():%Y-%m-%d %H:%M} UTC · window {dt.datetime.utcfromtimestamp(start/1000):%Y-%m-%d %H:%M} → {dt.datetime.utcfromtimestamp(end/1000):%Y-%m-%d %H:%M} UTC",
             "Gross funding only: no trading fees, no price basis. APR % = persistent arbitrage from holding one side for the whole window; p95 bp = per-settlement-period extractable (95th percentile).", ""]
    for spec in args.bases.split(","):
        base, _, anchor = spec.partition(":")
        anchor = anchor or "binance"
        settled, missing = fetch(base, start, end)
        lines.append(f"## {base} (anchor: {anchor})\n")
        for v, why in missing.items():
            lines.append(f"- **{v} skipped**: {why}")
        if len(settled) < 2:
            lines.append("- fewer than two venues list it; nothing to compare\n")
            continue
        pols, notes = build_policies(base, settled, anchor)
        lines += [f"- {n}" for n in notes]
        fl, aprs, days = floor_apr(settled)
        lines.append(f"- venue funding over the common {days:.1f}-day window (APR %): " + ", ".join(f"{v} {a:+.2f}" for v, a in aprs.items()))
        lines.append(f"- **theoretical floor** for any single charge path: {fl:.2f}% APR (half the spread between the highest- and lowest-paying venue)\n")
        venues = list(settled)
        lines += ["| policy | worst persistent arb (APR %) | worst p95 per period (bp) | " + " | ".join(f"{v}: APR % / p95 bp" for v in venues) + " |",
                  "|---|---|---|" + "---|" * len(venues)]
        scored = []
        for name, inc in pols.items():
            per = {v: arb.against(inc, settled[v]) for v in venues}
            scored.append((max(abs(r["persistent_apr_pct"]) for r in per.values()), max(r["p95_abs_bp"] for r in per.values()), name, per))
        for wa, wp, name, per in sorted(scored):
            lines.append(f"| {name} | {wa:.2f} | {wp:.2f} | " + " | ".join(f"{per[v]['persistent_apr_pct']:+.2f} / {per[v]['p95_abs_bp']:.2f}" for v in venues) + " |")
        lines.append("")
    out = "\n".join(lines)
    print(out)
    rep = os.path.join(os.path.dirname(__file__), "reports")
    os.makedirs(rep, exist_ok=True)
    path = os.path.join(rep, f"{dt.datetime.utcnow():%Y%m%d-%H%M}-{args.bases.replace(',', '_').replace(':', '-')}.md")
    with open(path, "w") as f:
        f.write(out + "\n")
    print(f"\nreport written: {path}")


if __name__ == "__main__":
    main()
