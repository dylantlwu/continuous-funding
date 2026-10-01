import unittest

from validation import arb, binance_recon, tracker


def period(start, length, settled, pred=None):
    return {"start": start, "end": start + length, "settled": settled, "pred": pred if pred is not None else [settled] * length}


def cum_at(inc, t):
    return sum(v for m, v in inc.items() if m < t)


class TrackerTests(unittest.TestCase):
    def test_constant_prediction_matches_venue_exactly_at_each_settlement(self):
        # Without this, the core claim "hold a full period on both sides and the funding is identical" is untested.
        ps = [period(0, 480, 1e-4), period(480, 480, 2e-4), period(960, 480, -5e-5)]
        inc = tracker.track(ps)
        venue = 0.0
        for p in ps:
            venue += p["settled"]
            self.assertAlmostEqual(cum_at(inc, p["end"]), venue, places=15)

    def test_late_surprise_is_carried_and_closed_next_period(self):
        # Without this, a residual from a last-minute prediction change could silently accumulate period after period.
        pred = [1e-4] * 475 + [3e-4] * 5          # prediction jumps inside the final H_MIN minutes
        ps = [period(0, 480, 3e-4, pred), period(480, 480, 1e-4)]
        inc = tracker.track(ps)
        first = abs(cum_at(inc, 480) - 3e-4)
        second = abs(cum_at(inc, 960) - 4e-4)
        self.assertGreater(first, 1e-6)          # a surprise inside H_MIN is deliberately not caught up at once
        self.assertLess(second, first / 50)      # but the carried residual shrinks sharply in the next period

    def test_interval_switch_8h_to_1h_keeps_parity(self):
        # Without this, Binance's automatic switch to 1h settlement after hitting the cap could break parity.
        ps = [period(0, 480, 3e-3), period(480, 60, 3e-3), period(540, 60, 1e-3)]
        inc = tracker.track(ps)
        self.assertAlmostEqual(cum_at(inc, 480), 3e-3, places=15)
        self.assertAlmostEqual(cum_at(inc, 540), 6e-3, places=15)
        self.assertAlmostEqual(cum_at(inc, 600), 7e-3, places=15)

    def test_last_minute_jump_cannot_spike_charge_beyond_gap_over_h_min(self):
        # Without this, someone who moves the venue's premium one minute before settlement could make us charge the whole gap in one minute.
        pred = [0.0] * 479 + [1e-2]
        inc = tracker.track([period(0, 480, 1e-2, pred)])
        # at most the normal pace plus 1/H_MIN of the gap in that minute
        self.assertLessEqual(inc[479], 1e-2 / 480 + 1e-2 / tracker.H_MIN + 1e-18)
        self.assertLess(inc[479], 1e-2 / 5)

    def test_missing_prediction_fails_loud(self):
        # Without this, a period with no data could be charged as zero and look like perfect tracking.
        with self.assertRaises(ValueError):
            tracker.track([{"start": 0, "end": 480, "settled": 1e-4, "pred": None}])


class ArbTests(unittest.TestCase):
    def test_perfect_tracking_leaves_nothing(self):
        # Without this, the scorer itself could report arbitrage that does not exist (or hide one that does).
        settled = [(0, 0.0), (480, 1e-4), (960, 1e-4), (1440, 1e-4)]
        inc = {m: 1e-4 / 480 for m in range(0, 1440)}
        r = arb.against(inc, settled)
        self.assertAlmostEqual(r["persistent_bp"], 0.0, places=9)
        self.assertAlmostEqual(r["max_abs_bp"], 0.0, places=9)

    def test_venue_paying_one_bp_more_per_period_is_measured(self):
        # Without this, a systematic spread (the most dangerous, repeatable arbitrage) could be mis-annualised.
        settled = [(0, 0.0)] + [(480 * k, 2e-4) for k in range(1, 91)]   # 30 days of 8h periods
        inc = {m: 1e-4 / 480 for m in range(0, 480 * 90)}
        r = arb.against(inc, settled)
        self.assertAlmostEqual(r["persistent_bp"], 90.0, places=6)
        self.assertAlmostEqual(r["persistent_apr_pct"], 100 * 90e-4 * 365 / 30, places=6)


class BinanceReconTests(unittest.TestCase):
    def test_premium_inside_dead_zone_gives_interest_only_rate(self):
        # Without this, the Binance formula's damper (why ~half of rates equal 0.01%) could be wrong and bias every backtest.
        path = binance_recon.predicted_path([0.0003] * 480, 480)
        self.assertAlmostEqual(path[-1], 0.0001, places=12)
        path4h = binance_recon.predicted_path([0.0003] * 240, 240)
        self.assertAlmostEqual(path4h[-1], 0.00005, places=12)

    def test_premium_outside_dead_zone_passes_through(self):
        # Without this, large premiums (the periods that matter most for arbitrage) could be clipped wrongly.
        path = binance_recon.predicted_path([0.002] * 480, 480)
        self.assertAlmostEqual(path[-1], 0.002 - 0.0005, places=12)


if __name__ == "__main__":
    unittest.main()


class VenueDedupeTests(unittest.TestCase):
    def test_two_records_in_same_minute_are_summed_not_dropped(self):
        # Without this, Binance's 'Special' funding one second after the regular one silently replaces it (real case: NVDA 2026-09-10).
        from validation.venues import _dedupe_sorted
        t = 1_790_000_000_000 - 1_790_000_000_000 % 60_000
        rows = [(t, 3.877e-5), (t + 1000, -1.11667e-3), (t, 3.877e-5)]   # regular, special, and a duplicate page copy
        out = _dedupe_sorted(rows, t - 60_000, t + 60_000)
        self.assertEqual(len(out), 1)
        self.assertAlmostEqual(out[0][1], 3.877e-5 - 1.11667e-3, places=12)


class RevisionTests(unittest.TestCase):
    def test_value_at_uses_value_in_force_not_next_one(self):
        # Without this, the revision study would read a prediction that was not yet published (look-ahead) and understate revisions.
        from validation.revisions import value_at
        s = [(1000, 1e-4), (5000, 2e-4)]
        self.assertIsNone(value_at(s, 999))
        self.assertEqual(value_at(s, 4999), 1e-4)
        self.assertEqual(value_at(s, 5000), 2e-4)


class VaultSimTests(unittest.TestCase):
    P = None

    def setUp(self):
        from validation import vault_sim
        self.vs = vault_sim
        self.P = dict(vault_sim.PARAMS, arb_threshold_apr=1e9)       # arbitrage off unless a test turns it on

    def _run(self, kind, crowd, prices, cons, venue_rate, P=None):
        hours = list(range(len(prices)))
        venue_h = {"x": {h: venue_rate for h in hours}}
        return self.vs.simulate(hours, prices, cons, venue_h, crowd, kind, P or self.P)

    def test_crowd_long_and_positive_rate_pays_the_vault(self):
        # Without this, a sign error would show the vault earning when it should pay (or vice versa) and invert every conclusion.
        r = 0.0001
        o = self._run("parity", [10.0] * 5, [100.0] * 5, [r] * 5, r)
        self.assertAlmostEqual(o["fund"], r * 10 * 100 * 4, places=12)
        self.assertEqual(o["dir"], 0.0)

    def test_price_up_with_crowd_long_costs_the_vault(self):
        # Without this, the vault's directional exposure (the dominant risk) could be booked with the wrong sign.
        o = self._run("parity", [10.0, 10.0], [100.0, 110.0], [0.0, 0.0], 0.0)
        self.assertAlmostEqual(o["dir"], -100.0, places=9)

    def test_arbitrageur_goes_long_when_venue_pays_more_and_adds_to_skew(self):
        # Without this, arbitrage could be simulated in the wrong direction, so "arb extracted" and skew effects would be meaningless.
        P = dict(self.P, arb_threshold_apr=0.01, arb_capacity=5.0)
        gap = 0.10 / self.vs.APR                                      # venue 10% APR above our rate: 5x the threshold
        o = self._run("parity", [0.0, 0.0], [100.0, 100.0], [0.0, 0.0], gap, P)
        self.assertGreater(o["arb"], 0.0)
        self.assertAlmostEqual(o["abs_skew"][0], 5.0)                # full capacity, long on our venue

    def test_hybrid_premium_never_leaves_the_band(self):
        # Without this, the band that caps how far we deviate from the market (and so what arbitrage can take) could silently fail.
        o = self._run("hybrid", [500.0] * 200, [100.0] * 200, [0.0] * 200, 0.0)
        self.assertLessEqual(max(o["dev"]), self.P["hybrid_band_apr"] + 1e-12)
