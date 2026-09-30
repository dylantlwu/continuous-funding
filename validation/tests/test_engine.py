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
