"""Tests for the accuracy changes: insulin types, slow meals, correction learning, daily dose and
carb ratios blended across time-of-day boundaries.

    python3 -m unittest discover -s server/tests
"""
import os
import sys
import unittest
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import dosing  # noqa: E402
import libre_server  # noqa: E402
import localtime  # noqa: E402

H = 3600


def utc(*args):
    return int(datetime(*args, tzinfo=timezone.utc).timestamp())


def insulin(ts, units, kind="rapid"):
    return {"kind": "insulin", "ts": ts, "units": units, "insulinType": kind}


def meal(ts, carbs, absorption=None):
    return {"kind": "meal", "ts": ts, "carbs": carbs, "absorption": absorption}


def params(morning=10, midday=12, evening=8, isf=50, tdd=40):
    return {"byTime": {"morning": {"carbRatio": morning}, "midday": {"carbRatio": midday}, "evening": {"carbRatio": evening}},
            "carbRatio": 10, "sensitivity": isf, "dailyDose": tdd}


class Isolated(unittest.TestCase):
    def setUp(self):
        self._saved = (dosing.INSULIN_PEAK, dosing.INSULIN_DIA, dosing.SLOW_MEAL_MINUTES, dict(dosing.LIMITS), localtime.TZ)
        localtime.configure("UTC")

    def tearDown(self):
        peak, dia, slow, limits, tz = self._saved
        dosing.configure_insulin({"peak": peak, "dia": dia, "slowMealMinutes": slow})
        dosing.LIMITS.clear()
        dosing.LIMITS.update(limits)
        localtime.TZ = tz


class InsulinTypes(Isolated):
    @staticmethod
    def peak_minute():
        """Minute of fastest action: where the fraction still active falls fastest."""
        return max(range(1, 300), key=lambda m: dosing.insulin_on_board(m - 1) - dosing.insulin_on_board(m))

    def test_default_is_unchanged(self):
        self.assertEqual((dosing.INSULIN_PEAK, dosing.INSULIN_DIA), (75, 360))
        self.assertAlmostEqual(dosing.insulin_on_board(180), 0.208, places=3)
        self.assertAlmostEqual(self.peak_minute(), 75, delta=1)

    def test_fiasp_and_lyumjev_peak_earlier(self):
        for name in ("fiasp", "Lyumjev"):
            dosing.configure_insulin({"rapid": name})
            self.assertAlmostEqual(self.peak_minute(), 55, delta=1)
            self.assertLess(dosing.insulin_on_board(75), 0.694)

    def test_named_types_and_custom_curve(self):
        dosing.configure_insulin({"rapid": "humalog"})
        self.assertEqual(dosing.INSULIN_PEAK, 75)
        dosing.configure_insulin({"peak": 65, "dia": 300})
        self.assertEqual(dosing.insulin_on_board(300), 0.0)
        self.assertAlmostEqual(self.peak_minute(), 65, delta=1)

    def test_curve_runs_from_all_to_nothing(self):
        dosing.configure_insulin({"rapid": "fiasp", "dia": 300})
        values = [dosing.insulin_on_board(m) for m in range(0, 301, 5)]
        self.assertEqual(values[0], 1.0)
        self.assertEqual(values[-1], 0.0)
        self.assertTrue(all(a >= b for a, b in zip(values, values[1:])))

    def test_bad_settings_are_refused(self):
        for cfg in ({"rapid": "water"}, {"peak": 10}, {"dia": 1000}, {"peak": 120, "dia": 200}, {"type": "fiasp"},
                    {"slowMealMinutes": 30}, {"peak": "fast"}):
            with self.subTest(cfg=cfg), self.assertRaises(ValueError):
                dosing.configure_insulin(cfg)


class SlowMeals(Isolated):
    NOW = utc(2026, 11, 20, 12)

    def test_slow_meal_absorbs_over_five_hours(self):
        self.assertEqual(dosing.carbs_absorbed(180), 1.0)
        self.assertLess(dosing.carbs_absorbed(180, 300), 0.8)
        self.assertEqual(dosing.carbs_absorbed(300, 300), 1.0)

    def test_slow_meal_is_still_on_board_after_three_hours(self):
        self.assertEqual(dosing._cob([meal(self.NOW - 3 * H, 60)], self.NOW), 0)
        self.assertGreater(dosing._cob([meal(self.NOW - 3 * H, 60, 300)], self.NOW), 10)

    def test_slow_meal_holds_a_rising_trend_for_longer(self):
        events = [meal(self.NOW - 3.5 * H, 60, 300)]
        s = dosing.suggest(params(), 0, 180, 1.5, events, self.NOW)
        self.assertGreater(s["carbsOnBoard"], 0)
        self.assertTrue(s["trendHeld"])
        s = dosing.suggest(params(), 0, 180, 1.5, [meal(self.NOW - 3.5 * H, 60)], self.NOW)
        self.assertFalse(s["trendHeld"])

    def test_requests(self):
        self.assertEqual(libre_server.absorption_of({"slow": True}), 300)
        self.assertEqual(libre_server.absorption_of({"absorption": 240}), 240)
        self.assertIsNone(libre_server.absorption_of({}))
        self.assertIsNone(libre_server.absorption_of({"slow": False}))
        for bad in (30, 600, "slow", True):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                libre_server.absorption_of({"absorption": bad})

    def test_slow_meal_is_stored_and_edited(self):
        import tempfile
        from unittest import mock
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(libre_server, "DB_PATH", os.path.join(tmp, "g.db")):
            e = libre_server.add_event({"kind": "meal", "carbs": 60, "slow": True})
            self.assertEqual((e["absorption"], e["slow"]), (300, True))
            e = libre_server.update_event(e["id"], {"slow": False})
            self.assertEqual((e["absorption"], e["slow"]), (None, False))
            e = libre_server.add_event({"kind": "insulin", "units": 2, "slow": True})
            self.assertIsNone(e["absorption"])

    def test_slow_meal_minutes_are_configurable(self):
        dosing.configure_insulin({"slowMealMinutes": 240})
        self.assertEqual(libre_server.absorption_of({"slow": True}), 240)


class CorrectionLearning(Isolated):
    T = utc(2026, 11, 20, 15)

    def readings(self, fn):
        return [(t, round(fn(t))) for t in range(self.T - 4 * H, self.T + 4 * H, 300)]

    def samples(self, events, fn=lambda t: 250 - max(0, t - utc(2026, 11, 20, 15)) / 60 * 0.5):
        readings = self.readings(fn)
        index = [r[0] for r in readings]
        return dosing._corrections(readings, index, dosing._rapid(events), dosing._meals(events), 70)

    def test_plain_correction_is_learned(self):
        self.assertEqual(len(self.samples([insulin(self.T, 2)])), 1)

    def test_earlier_insulin_still_active_skips_it(self):
        self.assertEqual(self.samples([insulin(self.T - 2 * H, 4), insulin(self.T, 2)]), [])  # about 1.8 u still active
        # A small dose long enough before leaves little active: the correction counts.
        self.assertEqual(len(self.samples([insulin(self.T - 5 * H, 2), insulin(self.T, 2)])), 1)

    def test_carbs_still_absorbing_skip_it(self):
        self.assertEqual(self.samples([meal(self.T - 2.5 * H, 60, 300), insulin(self.T, 2)]), [])
        self.assertEqual(len(self.samples([meal(self.T - 3.5 * H, 60), insulin(self.T, 2)])), 1)  # all absorbed

    def test_a_meal_in_the_next_three_hours_skips_it(self):
        self.assertEqual(self.samples([insulin(self.T, 2), meal(self.T + 2 * H, 30)]), [])

    def test_a_rise_is_kept(self):
        out = self.samples([insulin(self.T, 2)], fn=lambda t: 200 + max(0, t - self.T) / 60 * 0.2)
        self.assertEqual(len(out), 1)
        self.assertLess(out[0], 0)


class DailyDose(Isolated):
    def test_median_of_fully_logged_days(self):
        now = int(datetime.now(timezone.utc).timestamp())
        day = lambda n: now - n * 86400  # noqa: E731
        events = []
        for n, (long, rapid) in enumerate([(20, 20), (20, 22), (20, 18), (20, 24), (5, 0)], start=1):
            events += [insulin(day(n), long, "long")] + ([insulin(day(n) + 60, rapid)] if rapid else [])
        events += [insulin(now, 30)]  # today, still going: not counted
        self.assertEqual(dosing.daily_insulin(events), 41)  # median of 40, 42, 38, 44; 5 u is sparse

    def test_partial_first_day_is_left_out(self):
        now = int(datetime.now(timezone.utc).timestamp())
        events = [insulin(now - n * 86400, 40, "long") for n in (1, 2, 3)] + [insulin(now - 4 * 86400, 25, "long")]
        self.assertEqual(dosing.daily_insulin(events, since=now - 4 * 86400), 40)
        self.assertEqual(dosing.daily_insulin([insulin(now - 86400, 30, "long")]), 30)

    def test_days_without_long_acting_are_a_fallback(self):
        now = int(datetime.now(timezone.utc).timestamp())
        self.assertEqual(dosing.daily_insulin([insulin(now - 86400, 12), insulin(now - 2 * 86400, 14)]), 13)


class BlendedRatios(Isolated):
    P = params(morning=10, midday=12, evening=8)

    def at(self, h, m=0):
        return dosing.carb_ratio_at(self.P, utc(2026, 11, 20, h, m))

    def test_middle_of_a_period(self):
        self.assertEqual(self.at(8), 10)
        self.assertEqual(self.at(13), 12)
        self.assertEqual(self.at(20), 8)
        self.assertEqual(self.at(2), 8)

    def test_boundaries_change_gradually(self):
        self.assertEqual(self.at(10, 29), 10)
        self.assertEqual(self.at(10, 45), 10.5)
        self.assertEqual(self.at(11), 11)       # halfway between morning and midday
        self.assertEqual(self.at(11, 15), 11.5)
        self.assertEqual(self.at(11, 31), 12)
        self.assertEqual(self.at(16), 10)       # midday 12 to evening 8
        self.assertEqual(self.at(3, 45), 8.5)   # evening 8 to morning 10 around 04:00
        self.assertEqual(self.at(4), 9)

    def test_no_jump_across_a_boundary(self):
        values = [self.at(10, m) for m in range(0, 60)] + [self.at(11, m) for m in range(0, 60)]
        self.assertTrue(all(abs(a - b) <= 0.1 + 1e-9 for a, b in zip(values, values[1:])))

    def test_suggestion_uses_the_blended_ratio(self):
        s = dosing.suggest(self.P, 55, None, None, [], utc(2026, 11, 20, 11))
        self.assertEqual(s["periodCarbRatio"], 11)
        self.assertEqual(s["carbUnits"], 5.0)


if __name__ == "__main__":
    unittest.main()
