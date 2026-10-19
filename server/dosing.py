"""Rapid-insulin suggestions learned from the logged history.

Starting point: the usual rules of thumb from the average total daily dose (carb ratio 500/TDD,
sensitivity 1800/TDD). Each logged meal then shows what ratio it actually took: carbs absorbed
divided by insulin absorbed, adjusted for where glucose ended relative to where it started.
Correction doses taken away from meals do the same for sensitivity. The medians of those are
blended with the rules of thumb, so a few meals move the numbers a little and many move them a lot.
Absorption uses standard curves: carbs over 3 h, rapid insulin peaking at 75 min and lasting 6 h.

This is an estimate from self-logged data, not medical advice.
"""
import bisect
import math
from datetime import datetime

CARB_MINUTES = 180
INSULIN_DIA = 360
INSULIN_PEAK = 75
MEAL_GROUP = 45 * 60      # meals this close together share one dose


def carbs_absorbed(minutes):
    """Fraction of a meal's carbs absorbed after `minutes` (Loop's parabolic curve)."""
    t = max(0.0, min(1.0, minutes / CARB_MINUTES))
    return 2 * t * t if t < 0.5 else -1 + 4 * t - 2 * t * t


def _insulin_curve():
    td, tp = INSULIN_DIA, INSULIN_PEAK
    tau = tp * (1 - tp / td) / (1 - 2 * tp / td)
    a = 2 * tau / td
    s = 1 / (1 - a + (1 + a) * math.exp(-td / tau))
    return td, tau, a, s


_TD, _TAU, _A, _S = _insulin_curve()


def insulin_on_board(minutes):
    """Fraction of a rapid-acting dose still active after `minutes` (exponential model used by Loop/oref)."""
    t = minutes
    if t <= 0:
        return 1.0
    if t >= _TD:
        return 0.0
    return 1 - _S * (1 - _A) * ((t * t / (_TAU * _TD * (1 - _A)) - t / _TAU - 1) * math.exp(-t / _TAU) + 1)


def _absorbed(events, t0, t1, field, curve):
    total = 0.0
    for e in events:
        amount = e.get(field) or 0
        if amount and e["ts"] < t1:
            total += amount * (curve((t1 - e["ts"]) / 60) - curve((t0 - e["ts"]) / 60))
    return total


def _reading_at(readings, idx_ts, ts, tolerance=7 * 60):
    """Closest reading to ts within tolerance. readings sorted; idx_ts the list of their timestamps."""
    i = bisect.bisect_left(idx_ts, ts)
    best = None
    for j in (i - 1, i):
        if 0 <= j < len(readings) and abs(readings[j][0] - ts) <= tolerance:
            if best is None or abs(readings[j][0] - ts) < abs(best[0] - ts):
                best = readings[j]
    return best[1] if best else None


def daily_insulin(events):
    """Average total daily dose (rapid + long) over past days with insulin logged.

    Days with long-acting logged are preferred, since a day without it is probably incomplete.
    """
    days, with_long = {}, set()
    today = datetime.now().date()
    for e in events:
        if e["kind"] == "insulin" and e.get("units"):
            day = datetime.fromtimestamp(e["ts"]).date()
            days[day] = days.get(day, 0) + e["units"]
            if e.get("insulinType") == "long":
                with_long.add(day)
    full = [v for d, v in days.items() if d in with_long and d != today] \
        or [v for d, v in days.items() if d != today] or list(days.values())
    return sum(full) / len(full) if full else None


def _shrink(values, prior, k):
    """Median of values pulled towards prior as if prior were k extra observations."""
    if not values:
        return prior
    values = sorted(values)
    mid = len(values) // 2
    median = values[mid] if len(values) % 2 else (values[mid - 1] + values[mid]) / 2
    return (len(values) * median + k * prior) / (len(values) + k)


def _rapid(events):
    return [e for e in events if e["kind"] == "insulin" and (e.get("insulinType") or "rapid") == "rapid" and e.get("units")]


def _meals(events):
    return [e for e in events if e["kind"] == "meal" and e.get("carbs")]


def meal_groups(meals):
    """Meals less than 45 minutes apart, merged: [[meal, ...], ...] in time order."""
    groups = []
    for m in sorted(meals, key=lambda m: m["ts"]):
        if groups and m["ts"] - groups[-1][-1]["ts"] <= MEAL_GROUP:
            groups[-1].append(m)
        else:
            groups.append([m])
    return groups


def _corrections(readings, index, rapid, meals, low):
    """mg/dL drop per unit for doses taken with no meal 2 h before to 3 h after."""
    out = []
    for e in rapid:
        t = e["ts"]
        if any(t - 2 * 3600 <= m["ts"] <= t + 3 * 3600 for m in meals):
            continue
        if any(o is not e and abs(o["ts"] - t) <= 3 * 3600 for o in rapid):
            continue
        g0, g1 = _reading_at(readings, index, t), _reading_at(readings, index, t + 3 * 3600)
        inside = [v for _, v in readings[_lo(index, t):_lo(index, t + 3 * 3600)]]
        if g0 is None or g1 is None or not inside or min(inside) < low:
            continue
        absorbed = e["units"] * (1 - insulin_on_board(180))
        if g0 > g1:
            out.append((g0 - g1) / absorbed)
    return out


def _meal_ratios(readings, index, rapid, meals, isf, low):
    """Carb ratio implied by each meal: carbs absorbed / insulin it actually took.

    Insulin it took = insulin absorbed over the window, adjusted for where glucose ended up
    relative to where it started (ending higher means more was needed, at `isf` per unit).
    The window runs from the meal to 4 h later, or to the next meal or a low if sooner (at least 2 h).
    """
    out = []
    groups = meal_groups(meals)
    for gi, group in enumerate(groups):
        start = group[0]["ts"]
        end = start + 4 * 3600
        if gi + 1 < len(groups):
            end = min(end, groups[gi + 1][0]["ts"])
        lo = next((ts for ts, v in readings[_lo(index, start):_lo(index, end)] if v < low), None)
        if lo:
            end = lo
        if end - start < 2 * 3600 and not lo:
            continue
        g0, g1 = _reading_at(readings, index, start), _reading_at(readings, index, end)
        if g0 is None or g1 is None or g0 < low:
            continue
        carbs = _absorbed(meals, start, end, "carbs", carbs_absorbed)
        insulin = _absorbed(rapid, start, end, "units", lambda m: 1 - insulin_on_board(m))
        needed = insulin + (g1 - g0) / isf
        if carbs >= 10 and needed > 0.2:
            out.append({"ts": start, "ratio": max(2.0, min(40.0, carbs / needed))})
    return out


BUCKETS = (("morning", 4, 11), ("midday", 11, 16), ("evening", 16, 28))


def bucket(ts):
    h = datetime.fromtimestamp(ts).hour
    h = h + 24 if h < 4 else h
    return next(name for name, a, b in BUCKETS if a <= h < b)


def fit(readings, events, low=70):
    """Carb ratio (g/u) and sensitivity (mg/dL per u) from history. readings: [(ts, mgdl)] sorted.

    Starts from the rules of thumb (500 and 1800 divided by the total daily dose) and moves towards
    what the logged meals and correction doses show as they accumulate.
    """
    rapid, meals = _rapid(events), _meals(events)
    tdd = daily_insulin(events)
    if not tdd or not rapid or not readings:
        return None
    isf0, icr0 = 1800 / tdd, 500 / tdd
    index = [r[0] for r in readings]

    corrections = _corrections(readings, index, rapid, meals, low)
    isf = max(isf0 / 2, min(isf0 * 2, _shrink(corrections, isf0, 3)))
    ratios = _meal_ratios(readings, index, rapid, meals, isf, low)
    icr = _shrink([r["ratio"] for r in ratios], icr0, 3)
    by_time = {}
    for name, _, _ in BUCKETS:
        values = [r["ratio"] for r in ratios if bucket(r["ts"]) == name]
        by_time[name] = {"carbRatio": round(_shrink(values, icr, 2), 1), "meals": len(values)}
    return {
        "carbRatio": round(icr, 1),
        "sensitivity": round(isf),
        "byTime": by_time,
        "rulesCarbRatio": round(icr0, 1),
        "rulesSensitivity": round(isf0),
        "dailyDose": round(tdd, 1),
        "meals": len(ratios),
        "corrections": len(corrections),
        "days": round((readings[-1][0] - min(e["ts"] for e in events)) / 86400, 1),
    }


def _lo(index, ts):
    return bisect.bisect_left(index, ts)


def suggest(params, carbs, glucose, slope, events, now, target=120, low=70):
    """Rapid-insulin suggestion for `carbs` eaten now.

    glucose: latest mg/dL (None if unknown); slope: mg/dL per minute from the forecast (None if unknown).
    Insulin still active is subtracted, minus what the carbs still being absorbed will need.
    """
    period = bucket(now)
    icr, isf = params["byTime"][period]["carbRatio"], params["sensitivity"]
    rapid, meals = _rapid(events), _meals(events)
    iob = sum(e["units"] * insulin_on_board((now - e["ts"]) / 60) for e in rapid if e["ts"] <= now)
    cob = sum(e["carbs"] * (1 - carbs_absorbed((now - e["ts"]) / 60)) for e in meals if e["ts"] <= now)
    active = max(0.0, iob - cob / icr)

    carb_units = carbs / icr
    correction = (glucose - target) / isf if glucose is not None else 0.0
    trend = max(-60, min(60, slope * 30)) / isf if slope is not None and glucose is not None else 0.0
    total = carb_units + correction + trend - active

    warning = None
    if glucose is not None and glucose < low:
        warning = "You're below range: treat the low first, then dose for the meal once you're back up."
        total = 0.0
    elif glucose is None:
        warning = "No recent glucose reading, so there's no correction in this estimate."
    total = max(0.0, math.floor(total * 2) / 2)
    return {
        "units": total,
        "carbUnits": round(carb_units, 1),
        "correctionUnits": round(correction, 1),
        "trendUnits": round(trend, 1),
        "activeInsulin": round(iob, 1),
        "carbsOnBoard": round(cob),
        "activeDeducted": round(active, 1),
        "glucose": glucose,
        "target": target,
        "warning": warning,
        "period": period,
        "periodCarbRatio": icr,
        **params,
    }


def meal_dose(meal_ts, meals, insulin, readings, low, high, now, params=None):
    """How the rapid insulin around a meal worked out.

    meals/insulin: event dicts covering a few hours around the meal; readings: [(ts, mgdl)] from
    15 minutes before the meal to 3 hours after. Meals within 45 minutes of each other share a dose;
    rapid insulin from 1 h before to 90 min after counts as the meal's dose, later doses (before
    the next meal, within 3 h) as corrections.

    verdict: "ok", "tooLittle", "tooMuch", "none" (no insulin logged) or None (too early to tell,
    or the next meal came too soon).
    """
    group = [m for m in meals if abs(m["ts"] - meal_ts) <= MEAL_GROUP]
    start, end_group = min(m["ts"] for m in group), max(m["ts"] for m in group)
    carbs = sum(m.get("carbs") or 0 for m in group)
    rapid = _rapid(insulin)
    bolus = [e for e in rapid if start - 3600 <= e["ts"] <= end_group + 90 * 60]
    next_meal = min((m["ts"] for m in meals if m["ts"] > end_group + MEAL_GROUP), default=None)
    horizon = min(start + 3 * 3600, next_meal or 2 ** 40)
    later = [e for e in rapid if end_group + 90 * 60 < e["ts"] <= horizon]

    out = {
        "units": sum(e["units"] for e in bolus),
        "minutesFromMeal": round((bolus[0]["ts"] - start) / 60) if bolus else None,
        "laterUnits": sum(e["units"] for e in later),
        "carbs": carbs,
        "sharedWith": len(group) - 1,
        "suggested": round(carbs / params["byTime"][bucket(start)]["carbRatio"] * 2) / 2 if params and carbs else None,
        "verdict": None,
        "reason": None,
    }
    if not bolus:
        out["verdict"] = "none"
        out["reason"] = "No rapid insulin logged with this meal"
        if later:
            out["reason"] += f"; {_fmt(out['laterUnits'])} u taken later"
        return out

    before = [(abs(ts - start), v) for ts, v in readings if start - 15 * 60 <= ts <= start + 10 * 60]
    after = [(ts, v) for ts, v in readings if start <= ts <= horizon]
    if not before or len(after) < 3:
        return out
    baseline = min(before)[1]
    if baseline < low:
        out["reason"] = "Eaten while low"
        return out
    low_hit = next(((ts, v) for ts, v in after if v < low and ts >= start + 30 * 60), None)
    if low_hit:
        out["verdict"] = "tooMuch"
        out["reason"] = f"Went down to {low_hit[1]} at {datetime.fromtimestamp(low_hit[0]):%H:%M}"
        return out
    if horizon - start < 2 * 3600:
        out["reason"] = "The next meal came too soon to judge the dose"
        return out
    if now < horizon:
        return out
    end = after[-1][1]
    hours = round((horizon - start) / 3600, 1)
    # Starting high, a good dose also brings glucose down; starting in range, it returns there.
    expected = min(baseline, high)
    if later:
        out["verdict"] = "tooLittle"
        out["reason"] = f"Needed {_fmt(out['laterUnits'])} u more later"
    elif end - expected > 60 or (end > high and end > baseline - 30):
        out["verdict"] = "tooLittle"
        out["reason"] = f"Still at {end} after {_fmt(hours)} h, from {baseline} before the meal"
    elif end < min(baseline, 120) - 40:
        out["verdict"] = "tooMuch"
        out["reason"] = f"Down to {end} after {_fmt(hours)} h, from {baseline} before the meal"
    else:
        out["verdict"] = "ok"
        out["reason"] = f"At {end} after {_fmt(hours)} h, from {baseline} before the meal"
    return out


def _fmt(u):
    return str(int(u)) if u == int(u) else f"{u:.1f}"
