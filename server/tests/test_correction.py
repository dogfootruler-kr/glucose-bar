"""Tests for the correction reminders.

    python3 -m unittest discover -s server/tests
"""
import os
import sys
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import correction  # noqa: E402
import dosing  # noqa: E402
import libre_server  # noqa: E402

NOW = 1_800_000_000
M = 60


def params(isf=50, tdd=40):
    return {"byTime": {k: {"carbRatio": 10} for k in ("morning", "midday", "evening")},
            "carbRatio": 10, "sensitivity": isf, "dailyDose": tdd}


def readings(minutes_high, value=250, before=120, step=5):
    """Readings every `step` min over the last 2 h: `before`, then `value` for the last minutes_high minutes."""
    return [(NOW - m * M, value if m <= minutes_high else before) for m in range(120, -1, -step)]


def rapid(minutes_ago, units):
    return {"kind": "insulin", "ts": NOW - minutes_ago * M, "units": units, "insulinType": "rapid"}


def meal(minutes_ago, carbs):
    return {"kind": "meal", "ts": NOW - minutes_ago * M, "carbs": carbs}


class Correction(unittest.TestCase):
    def setUp(self):
        self._saved = (dict(correction.LIMITS), dict(dosing.LIMITS))

    def tearDown(self):
        for target, saved in zip((correction.LIMITS, dosing.LIMITS), self._saved):
            target.clear()
            target.update(saved)

    def check(self, rows, slope=0.0, events=(), high=180, glucose=None, p=None):
        """correction.check with the real dose suggestion for no carbs."""
        events = list(events)
        g = glucose if glucose is not None else (rows[-1][1] if rows else None)

        def suggest():
            return dosing.suggest(p or params(), 0, g, slope, events, NOW, 120, 70)
        return correction.check(rows, slope, events, NOW, high, suggest)

    def test_sustained_high_reminds(self):
        c = self.check(readings(40))
        self.assertTrue(c["due"])
        self.assertEqual(c["units"], 2.5)  # (250 - 120) / 50 = 2.6, rounded down
        self.assertEqual(c["minutesHigh"], 40)
        self.assertEqual(c["since"], NOW - 40 * M)
        self.assertIn("Suggested correction: 2.5 u", c["text"])
        self.assertIn("Check before dosing", c["text"])
        self.assertEqual(c["repeatMinutes"], 120)

    def test_single_high_reading_does_not(self):
        self.assertEqual(self.check(readings(0))["reason"], "notHighLongEnough")

    def test_high_for_less_than_30_min_does_not(self):
        c = self.check(readings(25))
        self.assertFalse(c["due"])
        self.assertEqual((c["reason"], c["minutesHigh"]), ("notHighLongEnough", 25))

    def test_a_dip_below_high_restarts_the_clock(self):
        rows = [(ts, 170 if ts == NOW - 20 * M else v) for ts, v in readings(60)]
        self.assertEqual(self.check(rows)["reason"], "notHighLongEnough")

    def test_a_gap_in_the_data_restarts_the_clock(self):
        rows = [r for r in readings(60) if not NOW - 45 * M < r[0] < NOW - 20 * M]  # 25 min without readings
        self.assertEqual(self.check(rows)["reason"], "notHighLongEnough")

    def test_in_range_does_not(self):
        self.assertEqual(self.check(readings(60, value=170))["reason"], "notHigh")

    def test_uses_the_apps_high(self):
        self.assertTrue(self.check(readings(60, value=200), high=160)["due"])
        self.assertEqual(self.check(readings(60, value=200), high=220)["reason"], "notHigh")

    def test_falling_suppresses(self):
        self.assertEqual(self.check(readings(60), slope=-1.0)["reason"], "falling")
        self.assertTrue(self.check(readings(60), slope=-0.3)["due"])  # flat enough
        self.assertTrue(self.check(readings(60), slope=1.5)["due"])

    def test_unknown_trend_suppresses(self):
        self.assertEqual(self.check(readings(60), slope=None)["reason"], "noTrend")

    def test_stale_data_suppresses(self):
        rows = [(ts - 20 * M, v) for ts, v in readings(60)]
        self.assertEqual(self.check(rows)["reason"], "noRecentReading")
        self.assertEqual(self.check([])["reason"], "noRecentReading")

    def test_recent_rapid_dose_suppresses(self):
        self.assertEqual(self.check(readings(60), events=[rapid(150, 0.5)])["reason"], "recentInsulin")
        self.assertTrue(self.check(readings(60), events=[rapid(200, 0.5)])["due"])

    def test_insulin_still_active_reduces_the_dose(self):
        # 3 u four hours ago: past the cooldown, about 0.2 u still active.
        c = self.check(readings(60), events=[rapid(240, 3)])
        self.assertTrue(c["due"])
        self.assertEqual(c["units"], 2.0)  # 2.6 - 0.2 active = 2.4, rounded down to the half unit
        # With more still active, what's left is too small to remind about.
        dosing.LIMITS["trendRecentMinutes"] = 1
        c = self.check(readings(60, value=200), events=[rapid(200, 8)])
        self.assertEqual(c["reason"], "smallDose")

    def test_recent_carbs_suppress(self):
        self.assertEqual(self.check(readings(60), events=[meal(90, 50)])["reason"], "carbsOnBoard")
        self.assertTrue(self.check(readings(60), events=[meal(200, 50)])["due"])  # all absorbed

    def test_slow_meal_still_absorbing_suppresses(self):
        slow = {**meal(200, 60), "absorption": 300}
        self.assertEqual(self.check(readings(60), events=[slow])["reason"], "carbsOnBoard")

    def test_below_minimum_suppresses(self):
        c = self.check(readings(60, value=190), high=180)  # (190 - 120) / 50 = 1.4 -> 1.0, at the minimum
        self.assertTrue(c["due"])
        correction.configure({"minUnits": 1.5})
        c = self.check(readings(60, value=190), high=180)
        self.assertEqual((c["reason"], c["units"]), ("smallDose", 1.0))

    def test_cap_applies(self):
        c = self.check(readings(60, value=400), p=params(isf=20, tdd=20))  # 14 u worked out, capped at 5
        self.assertTrue(c["due"])
        self.assertEqual(c["units"], 5.0)
        self.assertIn("(capped)", c["text"])
        self.assertIn("capped", [a["kind"] for a in c["alerts"]])

    def test_heading_low_guard_applies(self):
        # Coming down fast enough to be low in 30 min, though not "falling" by this rule's setting.
        correction.configure({"fallingSlope": -10})
        c = self.check(readings(60, value=190), slope=-5)
        self.assertEqual(c["reason"], "smallDose")

    def test_no_dose_params_suppresses(self):
        c = correction.check(readings(60), 0.0, [], NOW, 180, lambda: None)
        self.assertEqual(c["reason"], "noDoseParams")

    def test_can_be_turned_off(self):
        correction.configure({"enabled": False})
        self.assertEqual(self.check(readings(60))["reason"], "off")

    def test_configure_refuses_bad_values(self):
        for cfg in ({"nope": 1}, {"enabled": "yes"}, {"minUnits": 0.1}, {"sustainedMinutes": 5},
                    {"fallingSlope": 1}, {"repeatMinutes": -5}, {"minUnits": True}):
            with self.subTest(cfg=cfg), self.assertRaises(ValueError):
                correction.configure(cfg)
            correction.LIMITS.update(self._saved[0])


class ServerStatus(unittest.TestCase):
    def test_server_uses_the_apps_range_and_never_raises(self):
        rows = readings(60)
        with mock.patch.object(libre_server, "history", return_value=rows), \
                mock.patch.object(libre_server, "events", return_value=[]), \
                mock.patch.object(libre_server.time, "time", return_value=NOW), \
                mock.patch.object(libre_server, "dose_suggestion",
                                  side_effect=lambda carbs, target, low: dosing.suggest(params(), 0, 250, 0.0, [], NOW, target, low)) as ds:
            c = libre_server.correction_status(high=200, low=80, target=110)
            self.assertTrue(c["due"])
            self.assertEqual(c["high"], 200)
            ds.assert_called_with(0, 110, 80)
            self.assertEqual(c["units"], 2.5)  # (250 - 110) / 50 = 2.8
        with mock.patch.object(libre_server, "history", side_effect=OSError("disk")), \
                mock.patch.object(libre_server, "log"):
            self.assertEqual(libre_server.correction_status(), {"due": False, "reason": "error"})

    def test_no_logged_insulin_means_no_reminder(self):
        with mock.patch.object(libre_server, "history", return_value=readings(60)), \
                mock.patch.object(libre_server, "events", return_value=[]), \
                mock.patch.object(libre_server.time, "time", return_value=NOW), \
                mock.patch.object(libre_server, "dose_suggestion", side_effect=RuntimeError("Log your insulin")):
            self.assertEqual(libre_server.correction_status()["reason"], "noDoseParams")

    def test_query_numbers(self):
        self.assertEqual(libre_server._int({"high": "200"}, "high"), 200)
        self.assertIsNone(libre_server._int({"high": "abc"}, "high"))
        self.assertIsNone(libre_server._int({}, "high"))


if __name__ == "__main__":
    unittest.main()
