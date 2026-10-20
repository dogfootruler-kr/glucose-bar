"""Derived data: short-term forecast, meal impact and the weekly data digest."""
from datetime import datetime, timedelta

import exercise

FORECAST_WINDOW = 20 * 60   # seconds of history used for the trend
FORECAST_MINUTES = 30
MEAL_WINDOW = 3 * 3600
EARLY_WINDOW = 90 * 60


def forecast(readings):
    """Linear trend over the last 20 minutes, projected 30 minutes ahead.

    readings: [(ts, mgdl)] sorted by ts. Returns None when there isn't enough recent data.
    """
    if not readings:
        return None
    last_ts, last = readings[-1]
    recent = [(ts, v) for ts, v in readings if ts >= last_ts - FORECAST_WINDOW]
    if len(recent) < 4 or recent[-1][0] - recent[0][0] < 10 * 60:
        return None
    n = len(recent)
    xs = [(ts - last_ts) / 60 for ts, _ in recent]
    ys = [v for _, v in recent]
    mx, my = sum(xs) / n, sum(ys) / n
    var = sum((x - mx) ** 2 for x in xs)
    if var == 0:
        return None
    slope = sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / var
    slope = max(-5.0, min(5.0, slope))  # mg/dL per minute; sensors rarely exceed this
    points = [{"ts": last_ts + m * 60, "mgdl": round(last + slope * m)} for m in range(5, FORECAST_MINUTES + 1, 5)]
    return {"slope": round(slope, 2), "from": last, "fromTs": last_ts, "points": points}


def _above(after, high):
    """Seconds above high, counting at most 15 minutes per gap between readings."""
    return sum(min(t1 - t0, 15 * 60) for (t0, v0), (t1, _) in zip(after, after[1:]) if v0 > high)


def meal_impact(meal_ts, readings, high, now, fx=None):
    """How glucose responded in the 3 hours after a meal. readings: [(ts, mgdl)] covering the window.

    fx: exercise effects (dosing.NoExercise). The scores use glucose as it would have been without
    the exercise, so a walk after eating doesn't make the food look better than it was; the other
    numbers are what the sensor read.
    """
    before = [(abs(ts - meal_ts), v) for ts, v in readings if meal_ts - 15 * 60 <= ts <= meal_ts + 10 * 60]
    after = [(ts, v) for ts, v in readings if meal_ts <= ts <= meal_ts + MEAL_WINDOW]
    if not before or len(after) < 3:
        return None
    baseline = min(before)[1]
    peak_ts, peak = max(after, key=lambda r: r[1])
    rise = max(0, peak - baseline)
    above = _above(after, high)
    back = next((ts for ts, v in after if ts > peak_ts and v <= baseline + 20), None)

    adjusted = fx.adjust(after, meal_ts) if fx else after
    score = 100 - max(0, max(v for _, v in adjusted) - baseline - 30) * 0.6 - (_above(adjusted, high) / 60) * 0.15
    # The first 90 minutes mostly reflect the food (and how early the insulin went in); what
    # happens after mostly reflects whether the dose was right, so the food score ignores it.
    early = [v for ts, v in adjusted if ts <= meal_ts + EARLY_WINDOW] or [baseline]
    early_rise = max(0, max(early) - baseline)
    food_score = 100 - max(0, early_rise - 30) * 0.6
    exercised = round(fx.lowered(meal_ts, meal_ts + EARLY_WINDOW)) if fx else 0
    return {
        "baseline": baseline,
        "peak": peak,
        "rise": rise,
        "minutesToPeak": round((peak_ts - meal_ts) / 60),
        "minutesAboveHigh": round(above / 60),
        "minutesToBaseline": round((back - meal_ts) / 60) if back else None,
        "score": int(max(0, min(100, round(score)))),
        "earlyRise": early_rise,
        "foodScore": int(max(0, min(100, round(food_score)))),
        "exerciseEffect": exercised if abs(exercised) >= 10 else None,
        "complete": now >= meal_ts + MEAL_WINDOW,
    }


def _stats(vals, low, high):
    if not vals:
        return None
    avg = sum(vals) / len(vals)
    return {
        "average": round(avg),
        "inRange": round(100 * sum(low <= v <= high for v in vals) / len(vals)),
        "below": round(100 * sum(v < low for v in vals) / len(vals)),
        "above": round(100 * sum(v > high for v in vals) / len(vals)),
        "min": min(vals),
        "max": max(vals),
    }


def _episodes(readings, test, min_minutes=15, tag=None):
    """Contiguous runs where test(value) holds for at least min_minutes. tag(start ts) adds "afterExercise"."""
    out, start, worst = [], None, None
    for ts, v in readings + [(None, None)]:
        if ts is not None and test(v):
            start = start or ts
            worst = v if worst is None else (min(worst, v) if v < 100 else max(worst, v))
            end = ts
        elif start:
            if end - start >= min_minutes * 60:
                out.append({"start": datetime.fromtimestamp(start).strftime("%a %H:%M"),
                            "minutes": round((end - start) / 60), "extreme": worst})
                if tag and tag(start):
                    out[-1]["afterExercise"] = tag(start)
            start, worst = None, None
    return out


def weekly_digest(readings, prev_readings, events, meals, low, high, start, end, sessions=()):
    """Compact numbers for the weekly summary prompt. Times are local. sessions: past exercise with "impact"."""
    days = {}
    hours = {h: [] for h in range(24)}
    for ts, v in readings:
        dt = datetime.fromtimestamp(ts)
        days.setdefault(dt.strftime("%a %d %b"), []).append(v)
        hours[dt.hour].append(v)

    insulin = {}
    for e in events:
        if e["kind"] == "insulin":
            day = datetime.fromtimestamp(e["ts"]).strftime("%a %d %b")
            key = f"{e.get('insulinType') or 'rapid'}_units"
            insulin.setdefault(day, {}).setdefault(key, 0)
            insulin[day][key] += e.get("units") or 0

    return {
        "period": f"{datetime.fromtimestamp(start):%a %d %b} to {datetime.fromtimestamp(end):%a %d %b %Y}",
        "targetRange": [low, high],
        "week": _stats([v for _, v in readings], low, high),
        "previousWeek": _stats([v for _, v in prev_readings], low, high),
        "byDay": {d: _stats(v, low, high) for d, v in days.items()},
        "averageByHour": {f"{h:02d}:00": round(sum(v) / len(v)) for h, v in hours.items() if v},
        "lowEpisodes": _episodes(readings, lambda v: v < low, tag=lambda ts: next(
            (exercise.label(e) for e in reversed(sessions) if exercise.ends_at(e) <= ts <= exercise.ends_at(e) + 12 * 3600), None)),
        "highEpisodes": _episodes(readings, lambda v: v > 250, 30),
        "insulinByDay": insulin,
        "meals": [{
            "when": datetime.fromtimestamp(m["ts"]).strftime("%a %H:%M"),
            "what": m.get("note") or "unnamed",
            "carbs": m.get("carbs"),
            "rise": (m.get("impact") or {}).get("rise"),
            "minutesAboveHigh": (m.get("impact") or {}).get("minutesAboveHigh"),
            "score": (m.get("impact") or {}).get("score"),
            "foodScore": (m.get("impact") or {}).get("foodScore"),
            "rapidInsulin": (m.get("dose") or {}).get("units"),
            "insulinMinutesFromMeal": (m.get("dose") or {}).get("minutesFromMeal"),
            "doseVerdict": (m.get("dose") or {}).get("verdict"),
            "doseNote": (m.get("dose") or {}).get("reason"),
            "exercise": (m.get("exercise") or {}).get("items"),
            "exerciseLoweredGlucoseBy": (m.get("exercise") or {}).get("effect"),
        } for m in meals],
        "exercise": exercise.digest(sessions),
    }


def week_bounds(now):
    """The 7 days ending now, and the 7 days before that."""
    end = now
    start = end - timedelta(days=7)
    return start, end, start - timedelta(days=7)
