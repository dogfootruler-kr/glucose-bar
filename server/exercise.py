"""Exercise: how much a logged session lowered glucose, so meals, doses and the learned ratios can allow for it.

Two effects, both starting from rules of thumb:
- During the activity glucose falls at a steady rate set by the activity and intensity, easing off
  over the hour after (strength work tends to push it up a little instead). The rate is learned
  per kind of exercise from finished sessions: the drop seen, less what the logged carbs and
  insulin explain, pulled towards the rule of thumb like the dosing ratios are.
- Afterwards insulin works harder for up to a day, fading. This one isn't learned.
Rates are per minute for someone with a sensitivity of 50 mg/dL per unit and scale with theirs.

This is an estimate from self-logged data, not medical advice.
"""
import bisect
import math
from datetime import datetime

import dosing

ACTIVITIES = ("walk", "run", "cycling", "strength", "swim", "sport", "other")
INTENSITIES = ("light", "moderate", "hard")
NAMES = {"cycling": "ride", "strength": "strength session", "sport": "sport", "other": "exercise"}
PLAN_AHEAD = 6 * 3600     # how far ahead exercise can be logged
TAIL = 60                 # minutes the drop takes to fade after the activity ends
ISF_REF = 50
MAX_ADJUST = 120          # most one window's glucose is ever corrected by, in case the model is off
FACTOR = {"walk": .8, "run": 1.0, "cycling": 1.0, "swim": .8, "sport": .9, "strength": 1.0, "other": .7}
PRIOR_RATE = {            # mg/dL per minute at ISF_REF; hard aerobic is lower than you'd guess as sprints push glucose up
    "aerobic.light": .25, "aerobic.moderate": .65, "aerobic.hard": .85,
    "anaerobic.light": .25, "anaerobic.moderate": .10, "anaerobic.hard": -.25,
}
BOOST_PEAK = {"light": .10, "moderate": .30, "hard": .50}    # how much harder insulin works right after
BOOST_TAU, BOOST_SPAN, BOOST_CAP = 480, 1440, .6             # minutes to fade to a third, minutes it lasts
GUIDE = {"light": 0, "moderate": .25, "hard": .40}           # usual meal-dose cut for exercise near the meal
ALERT_RAISE = {"moderate": 15, "hard": 25}                   # mg/dL earlier low alerts come after exercise
ALERT_HOURS = {"moderate": 4, "hard": 6}                     # how long for (2 h more after 90 min or longer)
ALERT_LOOKAHEAD = 30                                         # minutes ahead heading-low alerts look then, instead of 20


def sessions(events):
    """The exercise among events, oldest first."""
    return sorted((e for e in events if e["kind"] == "exercise" and e.get("minutes")), key=lambda e: e["ts"])


def ends_at(e):
    return e["ts"] + e["minutes"] * 60


def label(e):
    """What the session was, e.g. "45 min moderate run"."""
    return f"{round(e['minutes'])} min {e['intensity']} {NAMES.get(e['activity'], e['activity'])}"


def validate(e, now):
    if e.get("activity") not in ACTIVITIES:
        raise ValueError(f"activity must be one of {', '.join(ACTIVITIES)}")
    if e.get("intensity") not in INTENSITIES:
        raise ValueError(f"intensity must be one of {', '.join(INTENSITIES)}")
    if not 1 <= (e.get("minutes") or 0) <= 600:
        raise ValueError("Duration must be between 1 and 600 minutes")
    if e["ts"] > now + PLAN_AHEAD:
        raise ValueError("Exercise can be planned up to 6 hours ahead")


def _key(e):
    return f"{'anaerobic' if e['activity'] == 'strength' else 'aerobic'}.{e['intensity']}"


def default_model():
    return {"rates": dict(PRIOR_RATE), "sessions": {k: 0 for k in PRIOR_RATE}}


def _scale(e, isf):
    return FACTOR[e["activity"]] * max(.5, min(2.0, isf / ISF_REF))


def _shape(e, t):
    """Minutes of full-rate effect by t: flat during the activity, fading to nothing over TAIL after."""
    u, d = (t - e["ts"]) / 60, e["minutes"]
    if u <= 0:
        return 0.0
    if u <= d:
        return u
    v = min(u - d, TAIL)
    return d + v - v * v / (2 * TAIL)


def boost(exercises, t):
    """How much harder insulin works at t because of earlier exercise (0.3 = 30% harder)."""
    best = 0.0
    for e in exercises:
        u = (t - ends_at(e)) / 60
        if 0 <= u <= BOOST_SPAN:
            best = max(best, BOOST_PEAK[e["intensity"]] * min(1, e["minutes"] / 45) * math.exp(-u / BOOST_TAU))
    return min(BOOST_CAP, best)


class Effects(dosing.NoExercise):
    """What logged exercise did to glucose, for one set of rates, sensitivity and rapid doses."""

    def __init__(self, exercises, model, isf, rapid):
        self.exercises, self.model, self.isf = exercises, model, isf
        self.rapid = sorted(rapid, key=lambda e: e["ts"])

    def _acute(self, exercises, t):
        return sum(self.model["rates"][_key(e)] * _scale(e, self.isf) * _shape(e, t) for e in exercises)

    def _extra_insulin(self, exercises, t0, t1):
        """Units' worth of extra insulin action between t0 and t1 from insulin working harder."""
        n = max(1, math.ceil((t1 - t0) / 300))
        step, total = (t1 - t0) / n, 0.0
        lo = bisect.bisect_left([e["ts"] for e in self.rapid], t0 - dosing.INSULIN_DIA * 60)
        for i in range(n):
            a, b = t0 + i * step, t0 + (i + 1) * step
            k = boost(exercises, (a + b) / 2)
            if k:
                total += k * sum(e["units"] * (dosing.insulin_on_board((a - e["ts"]) / 60) - dosing.insulin_on_board((b - e["ts"]) / 60))
                                 for e in self.rapid[lo:] if e["ts"] < b)
        return total

    def _relevant(self, t0, t1):
        """Exercise whose drop or insulin boost reaches into [t0, t1]."""
        return [e for e in self.exercises if e["ts"] < t1 and ends_at(e) + BOOST_SPAN * 60 > t0]

    def adjust(self, readings, t0):
        if not readings:
            return readings
        exercises = self._relevant(t0, readings[-1][0])
        if not exercises:
            return readings
        out, extra, prev, a0 = [], 0.0, t0, self._acute(exercises, t0)
        for ts, v in readings:
            if ts <= t0:
                out.append((ts, v))
                continue
            extra += self._extra_insulin(exercises, prev, ts)
            prev = ts
            change = self._acute(exercises, ts) - a0 + self.isf * extra
            out.append((ts, v + round(max(-MAX_ADJUST, min(MAX_ADJUST, change)))))
        return out

    def lowered(self, t0, t1):
        return self.adjust([(t1, 0)], t0)[0][1] if t1 > t0 else 0.0

    def describe(self, t0, t1):
        labels = [label(e) for e in self.exercises
                  if (e["ts"] < t1 and ends_at(e) + TAIL * 60 > t0) or (e["ts"] < t0 and boost([e], t0) >= .1)]
        return list(dict.fromkeys(labels))


def _unexplained_drop(fx, meals, params, t0, t1, g0, g1):
    """How far glucose fell between t0 and t1 beyond what the carbs and insulin absorbed explain
    (with insulin working harder after earlier exercise), at the learned carb ratio and sensitivity."""
    icr, isf = params["byTime"][dosing.bucket(t0)]["carbRatio"], params["sensitivity"]
    carbs = dosing._absorbed(meals, t0, t1, "carbs", dosing.carbs_absorbed)
    insulin = dosing._absorbed(fx.rapid, t0, t1, "units", lambda m: 1 - dosing.insulin_on_board(m))
    insulin += fx._extra_insulin(fx._relevant(t0, t1), t0, t1)
    return isf * (carbs / icr - insulin) - (g1 - g0)


def learn(readings, events, params, low=70):
    """Drop rates per kind of exercise, from finished sessions that didn't overlap another one.

    Each session's window runs from its start to an hour after it ends, or to a low if sooner. The
    drop that the exercise accounts for is how far glucose fell beyond what the carbs and insulin
    absorbed in that window explain, at the learned carb ratio and sensitivity.
    """
    model = default_model()
    exercises, meals = sessions(events), dosing._meals(events)
    if not exercises or not readings:
        return model
    isf = params["sensitivity"]
    fx = Effects(exercises, model, isf, dosing._rapid(events))
    index = [r[0] for r in readings]
    samples = {}
    for e in exercises:
        t0, t1 = e["ts"], ends_at(e) + TAIL * 60
        if e["minutes"] < 10 or t1 > readings[-1][0]:
            continue
        if any(o is not e and o["ts"] < t1 and ends_at(o) + TAIL * 60 > t0 for o in exercises):
            continue
        t1 = next((ts for ts, v in readings[dosing._lo(index, t0):dosing._lo(index, t1)] if v < low), t1)
        g0, g1 = dosing._reading_at(readings, index, t0), dosing._reading_at(readings, index, t1)
        shape = _shape(e, t1)
        if g0 is None or g1 is None or shape < 10:
            continue
        dropped = _unexplained_drop(fx, meals, params, t0, t1, g0, g1)
        if abs(dropped) <= 200:
            samples.setdefault(_key(e), []).append(dropped / shape / _scale(e, isf))
    for key, values in samples.items():
        model["rates"][key] = round(max(-.8, min(2.0, dosing._shrink(values, PRIOR_RATE[key], 3))), 2)
        model["sessions"][key] = len(values)
    return model


def fit(readings, events, low=70):
    """(dosing params or None, Effects), with exercise allowed for in the dosing fit.

    Two passes: the ratios are fitted with the rule-of-thumb exercise rates, the rates are learned
    with those ratios, then the ratios are fitted again with the learned rates.
    """
    exercises, rapid = sessions(events), dosing._rapid(events)
    model = default_model()
    tdd = dosing.daily_insulin(events)
    if not exercises or not tdd:
        params = dosing.fit(readings, events, low)
        return params, Effects(exercises, model, params["sensitivity"] if params else ISF_REF, rapid)
    first = dosing.fit(readings, events, low, Effects(exercises, model, 1800 / tdd, rapid))
    if not first:
        return None, Effects(exercises, model, ISF_REF, rapid)
    model = learn(readings, events, first, low)
    params = dosing.fit(readings, events, low, Effects(exercises, model, first["sensitivity"], rapid))
    return params, Effects(exercises, model, params["sensitivity"], rapid)


def _timing(e, now):
    """How much the usual guidance applies to a meal eaten now: 1 for exercise within an hour of it."""
    if e["ts"] > now:
        minutes = (e["ts"] - now) / 60
        return 1 if minutes <= 60 else .5 if minutes <= 120 else 0
    if ends_at(e) > now:
        return 1
    minutes = (now - ends_at(e)) / 60
    return 1 if minutes <= 60 else .7 if minutes <= 120 else .4 if minutes <= 180 else 0


def when(e, now):
    """e.g. "in progress", "planned for 18:00", "ended 20 min ago"."""
    if e["ts"] > now:
        return f"planned for {datetime.fromtimestamp(e['ts']):%H:%M}"
    if ends_at(e) > now:
        return "in progress"
    minutes = round((now - ends_at(e)) / 60)
    return f"ended {minutes} min ago" if minutes < 90 else f"ended {round(minutes / 60)} h ago"


def dose_effect(fx, now):
    """For dosing.suggest: how much less rapid insulin a meal eaten now needs because of exercise
    in progress, planned in the next 2 h or done earlier.

    Near the meal it starts from the usual guidance (a quarter less for moderate exercise, 40% less
    for hard) and moves towards the model (the drop still to come plus insulin working harder) as
    that kind of exercise gets learned from. Never more than 60% of the dose.
    """
    near = [e for e in fx.exercises if e["ts"] <= now + 2 * 3600 and (_timing(e, now) or boost([e], now) >= .05)]
    if not near:
        return None

    def effect(carb_units, correction):
        dose = max(0.0, carb_units + correction)
        acute = (fx._acute(near, now + 3 * 3600) - fx._acute(near, now)) / fx.isf
        b = boost(near, now + 45 * 60)
        modelled = acute + dose * b / (1 + b)
        guided = [e for e in near if GUIDE[e["intensity"]] and _timing(e, now)]
        weights = [GUIDE[e["intensity"]] * _timing(e, now) * min(1, e["minutes"] / 30) for e in guided]
        guidance = min(.5 * carb_units, carb_units * sum(weights))
        learned = min((fx.model["sessions"][_key(e)] for e in guided), default=0)
        units = (learned * modelled + 3 * guidance) / (learned + 3) if guided else modelled
        units = max(0.0, min(units, .6 * dose))
        if units < .1:
            return None
        names = "; ".join(f"{label(e)}, {when(e, now)}" for e in sorted(near, key=lambda e: e["ts"]))
        return {
            "units": round(units, 1),
            "label": names[0].upper() + names[1:],
            "warning": "Exercise near a meal can take you low: keep fast carbs to hand and check again within the hour."
                       if guided else None,
        }

    return effect


def post_exercise(exercises, now):
    """After moderate or hard exercise glucose can keep falling for hours, so low alerts should come
    earlier: {untilTs, label, raise (mg/dL to add to the low threshold), lookahead (minutes)} or None."""
    active = []
    for e in exercises:
        if e["intensity"] in ALERT_RAISE and e["ts"] <= now:
            hours = ALERT_HOURS[e["intensity"]] + (2 if e["minutes"] >= 90 else 0)
            if ends_at(e) + hours * 3600 > now:
                active.append((ends_at(e) + hours * 3600, e))
    if not active:
        return None
    until, e = max(active, key=lambda a: a[0])
    return {"untilTs": until, "label": label(e), "raise": max(ALERT_RAISE[x["intensity"]] for _, x in active),
            "lookahead": ALERT_LOOKAHEAD}


def impact(e, readings, params, fx, events, low, now):
    """How glucose responded to one session. readings: [(ts, mgdl)] from its start to 12 h after it ends.

    expectedDrop is what the model puts down to the exercise; exerciseDrop what the data shows once
    the logged carbs and insulin are accounted for (needs the dosing params).
    """
    if e["ts"] > now:
        return None
    index = [r[0] for r in readings]
    finish = min(ends_at(e), now)
    g0, g1 = dosing._reading_at(readings, index, e["ts"]), dosing._reading_at(readings, index, finish)
    exercise_drop = None
    if params and g0 is not None and g1 is not None:
        exercise_drop = round(_unexplained_drop(fx, dosing._meals(events), params, e["ts"], finish, g0, g1))
    after = [(ts, v) for ts, v in readings if ends_at(e) <= ts <= ends_at(e) + 12 * 3600]
    lowest = min(after, key=lambda r: r[1], default=None)
    # Only a low that starts once glucose is back in range, not one carried over from the session.
    back = next((i for i, (_, v) in enumerate(after) if v >= low), len(after))
    first_low = next((i for i in range(back, len(after)) if after[i][1] < low), None)
    low_after = None
    if first_low is not None:
        run = after[first_low:]
        run = run[:next((i for i, (_, v) in enumerate(run) if v >= low), len(run))]
        ts, v = min(run, key=lambda r: r[1])
        low_after = {"mgdl": v, "ts": ts, "minutesAfter": round((after[first_low][0] - ends_at(e)) / 60)}
    return {
        "startGlucose": g0,
        "endGlucose": g1,
        "change": g1 - g0 if g0 is not None and g1 is not None else None,
        "expectedDrop": round(fx._acute([e], finish)),
        "exerciseDrop": exercise_drop,
        "lowest": {"mgdl": lowest[1], "ts": lowest[0]} if lowest else None,
        "lowAfter": low_after,
        "lowDuring": any(v < low for ts, v in readings if e["ts"] <= ts <= ends_at(e)),
        "inProgress": ends_at(e) > now,
        "complete": now >= ends_at(e) + 12 * 3600,
    }


def digest(exercises):
    """Rows for the weekly summary from past exercise events with their "impact"."""
    rows = []
    for e in exercises:
        i = e.get("impact") or {}
        low_after = i.get("lowAfter")
        rows.append({
            "when": datetime.fromtimestamp(e["ts"]).strftime("%a %H:%M"),
            "what": label(e),
            "note": e.get("note"),
            "glucoseChange": i.get("change"),
            "expectedDrop": i.get("expectedDrop"),
            "dropAfterCarbsAndInsulin": i.get("exerciseDrop"),
            "lowestNext12h": (i.get("lowest") or {}).get("mgdl"),
            "lowAfter": {"mgdl": low_after["mgdl"], "hoursAfter": round(low_after["minutesAfter"] / 60, 1)} if low_after else None,
        })
    return rows
