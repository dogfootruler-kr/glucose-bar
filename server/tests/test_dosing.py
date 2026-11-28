"""Tests for the dose suggestion's safety rules. Run from the repository root:

    python3 -m unittest discover -s server/tests
"""
import math
import os
import sys
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import dosing  # noqa: E402
import libre_server  # noqa: E402

NOW = 1_800_000_000


def params(icr=10, isf=50, tdd=40):
    return {"byTime": {k: {"carbRatio": icr, "meals": 0} for k in ("morning", "midday", "evening")},
            "carbRatio": icr, "sensitivity": isf, "dailyDose": tdd}


def meal(minutes_ago, carbs):
    return {"kind": "meal", "ts": NOW - minutes_ago * 60, "carbs": carbs}


def rapid(minutes_ago, units):
    return {"kind": "insulin", "ts": NOW - minutes_ago * 60, "units": units, "insulinType": "rapid"}


def suggest(carbs, glucose, slope, events=(), p=None, **kw):
    return dosing.suggest(p or params(), carbs, glucose, slope, list(events), NOW, **kw)


class LimitsTestCase(unittest.TestCase):
    def setUp(self):
        self._limits = dict(dosing.LIMITS)

    def tearDown(self):
        dosing.LIMITS.clear()
        dosing.LIMITS.update(self._limits)


class MaxDose(LimitsTestCase):
    def test_huge_meal_is_capped_at_share_of_daily_dose(self):
        # Before: 600 g at 350 mg/dL rising 3/min suggested 65.5 u.
        s = suggest(600, 350, 3)
        self.assertEqual(s["units"], 10.0)  # 0.25 x 40 u daily dose
        self.assertTrue(s["capped"])
        self.assertEqual(s["maxUnits"], 10.0)
        self.assertIn("Capped at 10 u", s["warning"])

    def test_hard_maximum_applies_with_a_large_daily_dose(self):
        s = suggest(600, 350, 3, p=params(tdd=100))
        self.assertEqual(s["units"], 15.0)
        self.assertTrue(s["capped"])

    def test_normal_meal_is_not_capped(self):
        s = suggest(50, 120, 0)
        self.assertEqual(s["units"], 5.0)
        self.assertFalse(s["capped"])
        self.assertIsNone(s["warning"])

    def test_cap_is_rounded_down_to_half_units(self):
        self.assertEqual(dosing.max_units(params(tdd=33)), 8.0)  # 8.25

    def test_cap_without_daily_dose_uses_hard_maximum(self):
        self.assertEqual(dosing.max_units({"dailyDose": None}), 15.0)


class RequestValidation(LimitsTestCase):
    def test_accepts_usual_values(self):
        dosing.validate_request(50, 120, 70)
        dosing.validate_request(0, 80, 50)
        dosing.validate_request(300, 200, 200)

    def test_rejects_bad_values(self):
        for carbs, target, low in ((-50, 120, 70), (301, 120, 70), (600, 120, 70), (math.nan, 120, 70),
                                   (math.inf, 120, 70), (50, 60, 70), (50, 250, 70), (50, 120, 40),
                                   (50, 120, 250), (None, 120, 70)):
            with self.subTest(carbs=carbs, target=target, low=low), self.assertRaises(ValueError):
                dosing.validate_request(carbs, target, low)

    def test_negative_carbs_never_give_insulin(self):
        self.assertEqual(suggest(-50, 120, 0)["units"], 0.0)

    def test_dose_suggestion_validates_before_fitting(self):
        with mock.patch.object(libre_server, "fitted", side_effect=AssertionError("fitted called")):
            with self.assertRaises(ValueError):
                libre_server.dose_suggestion(-50, 120, 70)
            with self.assertRaises(ValueError):
                libre_server.dose_suggestion(50, 120, 10)


class HeadingLow(LimitsTestCase):
    def test_falling_fast_from_75_gives_no_insulin(self):
        # Before: 75 mg/dL falling 3/min with 60 g suggested 3.5 u and no warning.
        s = suggest(60, 75, -3)
        self.assertEqual(s["units"], 0.0)
        self.assertEqual(s["predicted"], -15)
        self.assertEqual(s["correctionUnits"], 0.0)
        self.assertEqual(s["trendUnits"], 0.0)
        self.assertIn("heading low", s["warning"])

    def test_forecast_just_below_low_gives_no_insulin(self):
        s = suggest(60, 110, -1.5)  # 65 in 30 min
        self.assertEqual(s["units"], 0.0)
        self.assertIn("heading low", s["warning"])

    def test_forecast_above_low_still_doses_with_trend_taken_off(self):
        s = suggest(60, 110, -1)  # 80 in 30 min
        self.assertEqual(s["predicted"], 80)
        self.assertEqual(s["trendUnits"], -0.6)
        self.assertEqual(s["units"], 5.0)  # 6 - 0.2 correction - 0.6 trend = 5.2
        self.assertIsNone(s["warning"])

    def test_lookahead_is_configurable(self):
        dosing.configure({"lowLookahead": 10})
        self.assertGreater(suggest(60, 110, -1.5)["units"], 0)  # 95 in 10 min


class TrendDoubleCount(LimitsTestCase):
    def test_second_helping_while_rising(self):
        # Before: 20 g, 30 min after 50 g with 5 u, at 160 rising 2/min, suggested 4.0 u (1.2 u of it trend).
        s = suggest(20, 160, 2, [meal(30, 50), rapid(30, 5)])
        self.assertTrue(s["trendHeld"])
        self.assertEqual(s["trendUnits"], 0.0)
        self.assertEqual(s["units"], 2.5)  # 2.0 carbs + 0.8 correction

    def test_rise_soon_after_a_correction_adds_nothing(self):
        s = suggest(0, 200, 2, [rapid(90, 1)])
        self.assertTrue(s["trendHeld"])
        self.assertEqual(s["trendUnits"], 0.0)

    def test_rise_with_insulin_still_active_adds_nothing(self):
        s = suggest(30, 180, 2, [rapid(150, 4)])  # outside the 2 h window, about 1.3 u still active
        self.assertGreater(s["activeDeducted"], 0)
        self.assertTrue(s["trendHeld"])
        self.assertEqual(s["trendUnits"], 0.0)

    def test_rise_with_nothing_on_board_counts(self):
        s = suggest(0, 150, 1)
        self.assertFalse(s["trendHeld"])
        self.assertEqual(s["trendUnits"], 0.6)
        self.assertEqual(s["units"], 1.0)  # 0.6 correction + 0.6 trend = 1.2

    def test_fall_counts_even_with_carbs_on_board(self):
        s = suggest(30, 180, -1, [meal(30, 50), rapid(30, 5)])
        self.assertFalse(s["trendHeld"])
        self.assertEqual(s["trendUnits"], -0.6)


class MissingOrLowGlucose(LimitsTestCase):
    def test_stale_glucose_doses_for_carbs_only(self):
        s = suggest(50, None, None)
        self.assertEqual(s["units"], 5.0)
        self.assertEqual(s["correctionUnits"], 0.0)
        self.assertEqual(s["trendUnits"], 0.0)
        self.assertIsNone(s["predicted"])
        self.assertIn("No recent glucose reading", s["warning"])

    def test_stale_glucose_is_still_capped(self):
        s = suggest(200, None, None)
        self.assertEqual(s["units"], 10.0)
        self.assertIn("No recent glucose reading", s["warning"])
        self.assertIn("Capped", s["warning"])

    def test_below_low_gives_no_insulin(self):
        s = suggest(60, 65, 0)
        self.assertEqual(s["units"], 0.0)
        self.assertIn("below range", s["warning"])

    def test_below_low_while_rising_gives_no_insulin(self):
        s = suggest(60, 65, 3)
        self.assertEqual(s["units"], 0.0)
        self.assertIn("below range", s["warning"])

    def test_dose_suggestion_ignores_readings_older_than_15_minutes(self):
        now = 1_800_000_000
        readings = [(now - 20 * 60 + i * 60, 150) for i in range(5)]  # last one 16 min old
        with mock.patch.object(libre_server, "fitted", return_value=(params(), dosing.NO_EXERCISE)), \
                mock.patch.object(libre_server, "history", return_value=readings), \
                mock.patch.object(libre_server, "events", return_value=[]), \
                mock.patch.object(libre_server.exercise, "dose_effect", return_value=None), \
                mock.patch.object(libre_server.time, "time", return_value=now):
            s = libre_server.dose_suggestion(50, 120, 70)
        self.assertIsNone(s["glucose"])
        self.assertEqual(s["units"], 5.0)


class Configure(LimitsTestCase):
    def test_overrides(self):
        dosing.configure({"maxDoseUnits": 8, "maxDoseFraction": 0.5})
        self.assertEqual(suggest(600, 350, 3)["units"], 8.0)

    def test_none_keeps_defaults(self):
        dosing.configure(None)
        self.assertEqual(dosing.LIMITS, self._limits)

    def test_rejects_bad_settings(self):
        for cfg in ({"maxDose": 10}, {"maxDoseUnits": -1}, {"maxDoseUnits": 0}, {"maxDoseUnits": "10"},
                    {"maxDoseUnits": True}, {"maxDoseFraction": 1.5}):
            with self.subTest(cfg=cfg), self.assertRaises(ValueError):
                dosing.configure(cfg)


def formula(units, carb_units, max_units=10.0):
    return {"units": units, "carbUnits": carb_units, "maxUnits": max_units}


class AiClamp(LimitsTestCase):
    def test_increase_is_capped_in_units(self):
        self.assertEqual(libre_server.ai_units(formula(6, 6), 15), 8.0)  # +2 u, not 1.5x = 9

    def test_increase_is_capped_at_half_the_carb_part(self):
        # 2 u carbs + 4 u correction: the correction isn't scaled, so at most +1 u.
        self.assertEqual(libre_server.ai_units(formula(6, 2), 9), 7.0)

    def test_decrease_is_limited_to_half_the_carb_part(self):
        self.assertEqual(libre_server.ai_units(formula(6, 2), 0), 5.0)
        self.assertEqual(libre_server.ai_units(formula(6, 6), 0), 3.0)

    def test_never_above_the_formula_cap(self):
        self.assertEqual(libre_server.ai_units(formula(10, 10, max_units=10), 14), 10.0)

    def test_small_changes_round_down(self):
        self.assertEqual(libre_server.ai_units(formula(5, 5), 5.4), 5.0)
        self.assertEqual(libre_server.ai_units(formula(5, 5), 5.5), 5.5)

    def test_max_increase_is_configurable(self):
        dosing.configure({"aiMaxIncrease": 1})
        self.assertEqual(libre_server.ai_units(formula(6, 6), 15), 7.0)

    def test_dose_from_history_applies_clamp_and_logs(self):
        s = {**suggest(60, 200, 0), "units": 7.5}
        s["carbUnits"] = 6.0
        past = {"id": 1, "note": "pasta", "estimate": None, "dose": {"verdict": "tooLittle"}}
        with mock.patch.object(libre_server, "dose_suggestion", return_value=s), \
                mock.patch.object(libre_server.ai, "available", return_value=True), \
                mock.patch.object(libre_server, "meals_with_impact", return_value=[past]), \
                mock.patch.object(libre_server, "past_meal", return_value={"id": 1}), \
                mock.patch.object(libre_server.ai, "adjust_dose",
                                  return_value={"matches": [1], "units": 14, "reason": "Ran high"}), \
                mock.patch.object(libre_server, "log") as log:
            out = libre_server.dose_from_history({"carbs": 60, "note": "pasta"})
        self.assertEqual(out["units"], 9.5)  # 7.5 + 2
        self.assertEqual(out["formulaUnits"], 7.5)
        self.assertEqual(out["history"]["units"], 2.0)
        self.assertIn("AI proposed 14 u", log.call_args[0][0])
        self.assertIn("used 9.5 u", log.call_args[0][0])


if __name__ == "__main__":
    unittest.main()
