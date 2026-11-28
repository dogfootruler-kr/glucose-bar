"""Tests for the time zone setting, sustained lows, carb ratio bounds, long-acting checks and web targets.

    python3 -m unittest discover -s server/tests
"""
import os
import sys
import time
import unittest
from datetime import datetime, timezone
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import basal  # noqa: E402
import dosing  # noqa: E402
import libre_server  # noqa: E402
import localtime  # noqa: E402

H = 3600


def utc(*args):
    return int(datetime(*args, tzinfo=timezone.utc).timestamp())


def insulin(ts, units, kind="rapid"):
    return {"kind": "insulin", "ts": ts, "units": units, "insulinType": kind}


def meal(ts, carbs):
    return {"kind": "meal", "ts": ts, "carbs": carbs}


def series(t0, t1, value, step=60):
    """Readings every `step` seconds from t0 to t1; value: number or function of ts."""
    return [(t, value(t) if callable(value) else value) for t in range(t0, t1 + 1, step)]


class Isolated(unittest.TestCase):
    """Restores every module setting a test may change."""

    def setUp(self):
        self._saved = (dict(dosing.LIMITS), dict(basal.LIMITS), dict(libre_server.TARGETS), localtime.TZ)

    def tearDown(self):
        for target, saved in zip((dosing.LIMITS, basal.LIMITS, libre_server.TARGETS), self._saved):
            target.clear()
            target.update(saved)
        localtime.TZ = self._saved[3]


class TimeZone(Isolated):
    def test_buckets_follow_the_configured_zone(self):
        ts = utc(2026, 11, 20, 0, 30)  # 09:30 in Seoul
        localtime.configure("Asia/Seoul")
        self.assertEqual(dosing.bucket(ts), "morning")
        localtime.configure("UTC")
        self.assertEqual(dosing.bucket(ts), "evening")  # 00:30 counts with the evening before

    def test_daily_dose_days_follow_the_configured_zone(self):
        # 14:00 and 16:00 UTC: different days in Seoul (23:00, 01:00), the same day in UTC.
        events = [insulin(utc(2026, 11, 20, 14), 10, "long"), insulin(utc(2026, 11, 20, 16), 10, "long")]
        localtime.configure("UTC")
        self.assertEqual(dosing.daily_insulin(events), 20)
        localtime.configure("Asia/Seoul")
        self.assertEqual(dosing.daily_insulin(events), 10)

    def test_messages_use_the_configured_zone(self):
        localtime.configure("Asia/Seoul")
        self.assertEqual(f"{localtime.at(utc(2026, 11, 20, 0, 30)):%H:%M}", "09:30")

    def test_unknown_zone_is_refused(self):
        for name in ("Mars/Olympus", "not a zone", 9):
            with self.subTest(name=name), self.assertRaises(ValueError):
                localtime.configure(name)

    def test_no_setting_is_server_local_time(self):
        localtime.configure(None)
        self.assertIsNone(localtime.TZ)
        ts = utc(2026, 11, 20, 0, 30)
        self.assertEqual(localtime.at(ts), datetime.fromtimestamp(ts))


class SustainedLows(Isolated):
    T0 = utc(2026, 11, 20, 12)

    def test_one_reading_below_low_is_not_a_low(self):
        readings = series(self.T0, self.T0 + H, lambda t: 60 if t == self.T0 + 1800 else 110)
        self.assertEqual(dosing.low_runs(readings, 70), [])

    def test_a_short_dip_is_not_a_low(self):
        readings = series(self.T0, self.T0 + H, lambda t: 60 if self.T0 + 1800 <= t < self.T0 + 2400 else 110)
        self.assertEqual(dosing.low_runs(readings, 70), [])  # 9 minutes

    def test_fifteen_minutes_below_is_a_low(self):
        readings = series(self.T0, self.T0 + H, lambda t: 60 - (t == self.T0 + 1980) * 5
                          if self.T0 + 1800 <= t <= self.T0 + 2700 else 110)
        runs = dosing.low_runs(readings, 70)
        self.assertEqual(len(runs), 1)
        self.assertEqual(runs[0]["start"], self.T0 + 1800)
        self.assertEqual((runs[0]["mgdl"], runs[0]["ts"]), (55, self.T0 + 1980))

    def test_two_readings_fifteen_minutes_apart_are_a_low(self):
        readings = [(self.T0, 110), (self.T0 + 900, 65), (self.T0 + 1800, 62), (self.T0 + 2700, 100)]
        self.assertEqual(len(dosing.low_runs(readings, 70)), 1)

    def test_a_gap_splits_a_low(self):
        readings = [(self.T0, 65), (self.T0 + 1500, 65)]  # 25 minutes apart
        self.assertEqual(dosing.low_runs(readings, 70), [])

    def test_duration_is_configurable(self):
        dosing.configure({"lowMinMinutes": 5})
        readings = series(self.T0, self.T0 + H, lambda t: 60 if self.T0 + 1800 <= t < self.T0 + 2400 else 110)
        self.assertEqual(len(dosing.low_runs(readings, 70)), 1)

    def test_first_low_sees_a_low_running_past_the_window(self):
        readings = series(self.T0, self.T0 + 2 * H, lambda t: 60 if t >= self.T0 + H - 300 else 110)
        index = [r[0] for r in readings]
        low = dosing.first_low(readings, 70, self.T0, self.T0 + H, index)
        self.assertEqual(low["start"], self.T0 + H - 300)

    def _meal_dose(self, readings):
        meals = [meal(self.T0, 60)]
        return dosing.meal_dose(self.T0, meals, [insulin(self.T0, 6)], readings, 70, 180, self.T0 + 5 * H)

    def test_meal_dose_ignores_a_compression_low(self):
        readings = series(self.T0 - 900, self.T0 + 3 * H, lambda t: 55 if t == self.T0 + 2 * H else 120)
        d = self._meal_dose(readings)
        self.assertEqual(d["verdict"], "ok")

    def test_meal_dose_counts_a_sustained_low(self):
        readings = series(self.T0 - 900, self.T0 + 3 * H, lambda t: 55 if self.T0 + 2 * H <= t <= self.T0 + 2 * H + 1200 else 120)
        d = self._meal_dose(readings)
        self.assertEqual(d["verdict"], "tooMuch")
        self.assertIn("Went down to 55", d["reason"])

    def test_correction_with_a_compression_low_is_still_learned_from(self):
        t = self.T0
        rapid = [insulin(t, 2)]
        falling = lambda ts: round(220 - (ts - t) / 60 * 0.4)  # noqa: E731
        compressed = series(t - 600, t + 4 * H, lambda ts: 50 if ts == t + H else falling(ts))
        sustained = series(t - 600, t + 4 * H, lambda ts: 50 if t + H <= ts <= t + H + 1200 else falling(ts))
        for readings, expected in ((compressed, 1), (sustained, 0)):
            index = [r[0] for r in readings]
            self.assertEqual(len(dosing._corrections(readings, index, rapid, [], 70)), expected)


class CarbRatioBounds(Isolated):
    def test_learned_ratio_stays_within_twice_the_rule(self):
        now = int(time.time())
        day0 = now - 10 * 86400
        events, readings = [], series(day0 - H, now - 86400, 120, step=300)
        for d in range(8):
            base = day0 + d * 86400
            events.append(insulin(base, 60, "long"))
            for h in (2, 8, 13):  # meals with hardly any insulin while glucose stays flat: a huge ratio
                events += [meal(base + h * H, 60), insulin(base + h * H, 0.5)]
        p = dosing.fit(readings, events)
        rule = p["rulesCarbRatio"]
        self.assertLessEqual(p["carbRatio"], round(rule * 2, 1) + 0.1)
        for b in p["byTime"].values():
            self.assertLessEqual(b["carbRatio"], round(rule * 2, 1) + 0.1)


class LongActing(Isolated):
    NOW = utc(2026, 11, 20, 12)

    def test_missed_dose_warns_after_26_hours(self):
        m = basal.missed([insulin(self.NOW - 30 * H, 20, "long")], self.NOW)
        self.assertEqual(m["hoursAgo"], 30.0)
        self.assertIn("No long-acting insulin logged in the last 30 h", m["warning"])

    def test_recent_dose_is_fine(self):
        self.assertIsNone(basal.missed([insulin(self.NOW - 20 * H, 20, "long")], self.NOW)["warning"])

    def test_no_long_acting_logged_gives_nothing(self):
        self.assertIsNone(basal.missed([insulin(self.NOW - H, 5)], self.NOW))

    def test_missed_hours_are_configurable(self):
        basal.configure({"longMissedHours": 40})
        self.assertIsNone(basal.missed([insulin(self.NOW - 30 * H, 20, "long")], self.NOW)["warning"])

    def test_dose_suggestion_carries_the_missed_warning(self):
        s = {"warning": "Capped at 10 u.", "alerts": [{"kind": "capped", "text": "Capped at 10 u."}]}
        out = libre_server.with_long_acting(s, basal.missed([insulin(self.NOW - 30 * H, 20, "long")], self.NOW))
        self.assertEqual([a["kind"] for a in out["alerts"]], ["capped", "missedLong"])
        self.assertTrue(out["warning"].startswith("Capped at 10 u. No long-acting"))
        self.assertEqual(out["longActing"]["units"], 20)
        self.assertEqual(libre_server.with_long_acting(s, None), {**s, "longActing": None})

    def _days(self, long, rapid, n=4):
        out = []
        for d in range(1, n + 1):
            out += [insulin(self.NOW - d * 86400, long, "long"), insulin(self.NOW - d * 86400 + H, rapid)]
        return out

    def test_share_in_the_usual_range(self):
        s = basal.share(self._days(20, 20), self.NOW)
        self.assertEqual((s["share"], s["days"], s["flag"]), (0.5, 4, None))

    def test_share_low_and_high_are_flagged(self):
        self.assertEqual(basal.share(self._days(10, 30), self.NOW)["flag"], "low")
        self.assertEqual(basal.share(self._days(35, 15), self.NOW)["flag"], "high")
        self.assertIn("Worth raising with your care team", basal.share(self._days(35, 15), self.NOW)["warning"])

    def test_share_needs_a_few_days(self):
        self.assertIsNone(basal.share(self._days(20, 20, n=2), self.NOW))

    def test_configure_refuses_bad_values(self):
        for cfg in ({"nope": 1}, {"driftLimit": -1}, {"shareMin": 0.7}, {"shareMax": 1.5}):
            with self.subTest(cfg=cfg), self.assertRaises(ValueError):
                basal.configure(dict(cfg))
            basal.LIMITS.update(self._saved[1])


class FastingDrift(Isolated):
    def setUp(self):
        super().setUp()
        localtime.configure("UTC")
        self.now = utc(2026, 11, 20, 7)  # just after the last night

    def nights(self, slope_per_hour, n=5, extra=()):
        """Readings every 5 min and events for n days: meals with insulin every 3 h from 07:00 to 19:00, then
        nothing until the next 07:00, glucose steady at 120 except from midnight to 07:00, when it moves by
        slope_per_hour."""
        readings, events = [], list(extra)
        for d in range(n, 0, -1):
            midnight = utc(2026, 11, 20) - d * 86400 + 86400
            for h in (-17, -14, -11, -8, -5):
                events += [meal(midnight + h * H, 40), insulin(midnight + h * H, 4)]
            readings += series(midnight - 17 * H, midnight, 120, step=300)
            readings += series(midnight + 300, midnight + 7 * H - 300,
                               lambda t, m=midnight: round(120 + slope_per_hour * (t - m) / H), step=300)
        return sorted(set(readings)), events

    def test_steady_rise_is_flagged(self):
        readings, events = self.nights(20)
        d = basal.drift(readings, events, 70, self.now)
        self.assertEqual(len(d["days"]), 5)
        self.assertEqual(d["flag"], "rising")
        self.assertAlmostEqual(d["median"], 20, delta=1)
        self.assertIn("rose more than 15 mg/dL an hour on 5 of 5 days", d["warning"])

    def test_steady_fall_is_flagged(self):
        readings, events = self.nights(-20)
        self.assertEqual(basal.drift(readings, events, 40, self.now)["flag"], "falling")

    def test_flat_nights_are_fine(self):
        readings, events = self.nights(3)
        d = basal.drift(readings, events, 70, self.now)
        self.assertIsNone(d["flag"])
        self.assertIsNone(d["warning"])

    def test_too_few_days_flags_nothing(self):
        readings, events = self.nights(25, n=2)
        d = basal.drift(readings, events, 70, self.now)
        self.assertEqual(len(d["days"]), 2)
        self.assertIsNone(d["flag"])

    def test_a_snack_or_correction_breaks_the_stretch(self):
        nights = [utc(2026, 11, 20) - d * 86400 + 86400 for d in range(5, 0, -1)]
        snacks = [meal(m + 2 * H, 20) for m in nights]  # 02:00 snack: only 02:00-06:00 ... is under 4 h after it
        readings, events = self.nights(20, extra=snacks)
        d = basal.drift(readings, events, 70, self.now)
        self.assertEqual(d["days"], [])  # midnight-02:00 is under 3 h and after the snack there's under 4 h clear
        readings, events = self.nights(20, extra=[insulin(m + H, 2) for m in nights])
        self.assertEqual(basal.drift(readings, events, 70, self.now)["days"], [])

    def test_exercise_excludes_the_night(self):
        nights = [utc(2026, 11, 20) - d * 86400 + 86400 for d in range(5, 0, -1)]
        sessions = [{"kind": "exercise", "ts": m - 2 * H, "minutes": 60, "activity": "run", "intensity": "hard"} for m in nights]
        readings, events = self.nights(20)
        self.assertEqual(basal.drift(readings, events, 70, self.now, sessions)["days"], [])

    def test_check_collects_the_warnings(self):
        readings, events = self.nights(20)
        events += [insulin(self.now - 30 * H, 20, "long")]
        c = basal.check(readings, events, 70, self.now)
        self.assertEqual(len(c["warnings"]), 2)  # missed dose and rising drift
        self.assertEqual(c["drift"]["flag"], "rising")


class WebTargets(Isolated):
    def test_defaults(self):
        self.assertEqual(libre_server.TARGETS, {"low": 70, "high": 180, "doseTarget": 120})

    def test_configured_targets(self):
        libre_server.configure_targets({"low": 80, "high": 160, "doseTarget": 110})
        self.assertEqual(libre_server.TARGETS, {"low": 80, "high": 160, "doseTarget": 110})

    def test_bad_targets_are_refused(self):
        for cfg in ({"low": 200, "high": 180}, {"lw": 70}, {"low": "70"}, {"doseTarget": 300}, {"low": 30}):
            with self.subTest(cfg=cfg), self.assertRaises(ValueError):
                libre_server.configure_targets(cfg)
            libre_server.TARGETS.update(self._saved[2])

    def test_web_page_uses_the_targets(self):
        with open(libre_server.WEB_PAGE) as f:
            page = f.read()
        self.assertNotIn("target=120", page)
        self.assertNotIn("target: 120", page)
        self.assertIn("fetch('/settings')", page)


if __name__ == "__main__":
    unittest.main()
