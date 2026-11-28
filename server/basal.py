"""Checks on the long-acting (basal) insulin, from the logged history. They only inform: none of
them changes a dose suggestion beyond adding a warning.

- missed: no long-acting logged for longer than usual (LIMITS["longMissedHours"]), when it has been
  logged before.
- drift: how glucose moves while fasting (no carbs for a few hours, little rapid insulin active, no
  exercise, no low just before). Steady basal holds it roughly flat; a rise or fall of more than
  LIMITS["driftLimit"] mg/dL per hour on most days can mean the long-acting dose doesn't fit.
- share: long-acting as a share of the total daily dose, usually somewhere around 30 to 60%.

This is an estimate from self-logged data, not medical advice: changes to insulin are for the care team.
"""
import bisect

import dosing
import localtime

LIMITS = {
    "longMissedHours": 26,    # warn when the last long-acting dose was longer ago than this
    "fastingCarbHours": 4,    # no carbs (or low) for this long before a fasting stretch
    "fastingMaxIob": 0.3,     # most rapid insulin still active (units) during a fasting stretch
    "fastingMinHours": 3,     # shortest fasting stretch measured
    "exerciseClearHours": 6,  # no exercise from this long before a fasting stretch
    "driftLimit": 15,         # mg/dL per hour while fasting that's flagged
    "driftDays": 14,          # days looked back over
    "driftMinDays": 3,        # days with a fasting stretch needed before anything is flagged
    "shareMin": 0.3,          # long-acting share of the daily dose below this is flagged
    "shareMax": 0.6,          # and above this
    "shareMinDays": 3,        # days with both kinds logged needed for the share
}
STEP = 5 * 60


def configure(cfg):
    """Override LIMITS from config.json's "basal" object (ValueError for unknown keys or bad values)."""
    for key, value in (cfg or {}).items():
        if key not in LIMITS:
            raise ValueError(f'unknown "basal" setting "{key}" (known: {", ".join(LIMITS)})')
        if isinstance(value, bool) or not isinstance(value, (int, float)) or value <= 0:
            raise ValueError(f'"basal.{key}" must be a positive number')
        LIMITS[key] = float(value)
    if LIMITS["shareMin"] >= LIMITS["shareMax"] or LIMITS["shareMax"] > 1:
        raise ValueError('"basal.shareMin" must be below "basal.shareMax", which is at most 1')


def _long(events):
    return sorted((e for e in events if e["kind"] == "insulin" and e.get("insulinType") == "long" and e.get("units")),
                  key=lambda e: e["ts"])


def missed(events, now):
    """{"lastTs", "hoursAgo", "units", "warning"} for the last long-acting dose, or None if none is logged."""
    doses = [e for e in _long(events) if e["ts"] <= now]
    if not doses:
        return None
    last = doses[-1]
    hours = (now - last["ts"]) / 3600
    warning = None
    if hours > LIMITS["longMissedHours"]:
        warning = (f"No long-acting insulin logged in the last {round(hours)} h. If you've missed a dose, "
                   "glucose can run higher than this suggestion expects; check with your care team's plan for a missed dose.")
    return {"lastTs": last["ts"], "hoursAgo": round(hours, 1), "units": last["units"], "warning": warning}


def _slope(points):
    """Least-squares slope of [(ts, mgdl)] in mg/dL per hour, or None."""
    n = len(points)
    if n < 2:
        return None
    mx = sum(t for t, _ in points) / n
    my = sum(v for _, v in points) / n
    var = sum((t - mx) ** 2 for t, _ in points)
    if not var:
        return None
    return sum((t - mx) * (v - my) for t, v in points) / var * 3600


def fasting_stretches(readings, events, low, since, until, exercises=()):
    """Fasting stretches between since and until: [{"start", "end", "hours", "drift" (mg/dL per hour)}].

    A moment counts as fasting when there were no logged carbs and no low in the last fastingCarbHours
    (lows are often treated with carbs that aren't logged), less than fastingMaxIob units of rapid insulin
    are active, and no exercise is under way or ended within exerciseClearHours.
    """
    if not readings:
        return []
    index = [r[0] for r in readings]
    rapid = sorted(dosing._rapid(events), key=lambda e: e["ts"])
    rapid_ts = [e["ts"] for e in rapid]
    carbs = sorted(e["ts"] for e in dosing._meals(events))
    carbs += [r["end"] for r in dosing.low_runs(readings, low)]
    carbs.sort()
    clear = LIMITS["fastingCarbHours"] * 3600
    busy = [(e["ts"], e["ts"] + e["minutes"] * 60 + LIMITS["exerciseClearHours"] * 3600) for e in exercises]

    def fasting(t):
        i = bisect.bisect_right(carbs, t)
        if i and t - carbs[i - 1] < clear:
            return False
        if any(a <= t <= b for a, b in busy):
            return False
        lo = bisect.bisect_left(rapid_ts, t - dosing.INSULIN_DIA * 60)
        iob = sum(e["units"] * dosing.insulin_on_board((t - e["ts"]) / 60) for e in rapid[lo:] if e["ts"] <= t)
        return iob < LIMITS["fastingMaxIob"]

    out = []

    def close(start, end):
        if end - start < LIMITS["fastingMinHours"] * 3600:
            return
        points = readings[bisect.bisect_left(index, start):bisect.bisect_right(index, end)]
        covered = len(points) >= 6 and points[-1][0] - points[0][0] >= 0.8 * (end - start)
        drift = _slope(points) if covered else None
        if drift is not None:
            out.append({"start": start, "end": end, "hours": round((end - start) / 3600, 1),
                        "drift": round(drift, 1), "overnight": localtime.at(start).hour < 6})

    # Stretches are cut at local midnight, so each belongs to one day.
    start, t = None, since - since % STEP
    while t <= until:
        ok = fasting(t)
        if start is not None and (not ok or localtime.at(t).date() != localtime.at(start).date()):
            close(start, t - STEP)
            start = None
        if ok and start is None:
            start = t
        t += STEP
    if start is not None:
        close(start, t - STEP)
    return out


def drift(readings, events, low, now, exercises=()):
    """Fasting drift over the last driftDays: per day, and flagged when most days rise or fall too fast.

    {"days": [{"date", "drift", "hours"}], "median", "flag": "rising" | "falling" | None, "warning"}
    """
    since = now - LIMITS["driftDays"] * 86400
    stretches = fasting_stretches(readings, events, low, since, now, exercises)
    by_day = {}
    for s in stretches:
        by_day.setdefault(localtime.at(s["start"]).date().isoformat(), []).append(s)
    days = []
    for date, items in sorted(by_day.items()):
        hours = sum(s["hours"] for s in items)
        days.append({"date": date, "hours": round(hours, 1),
                     "drift": round(sum(s["drift"] * s["hours"] for s in items) / hours, 1)})
    out = {"days": days, "stretches": len(stretches), "median": None, "flag": None, "warning": None}
    if not days:
        return out
    values = sorted(d["drift"] for d in days)
    mid = len(values) // 2
    out["median"] = values[mid] if len(values) % 2 else round((values[mid - 1] + values[mid]) / 2, 1)
    if len(days) < LIMITS["driftMinDays"]:
        return out
    limit = LIMITS["driftLimit"]
    rising = sum(d["drift"] > limit for d in days)
    falling = sum(d["drift"] < -limit for d in days)
    # "Consistently": over the limit on at least driftMinDays days and on more than half of them.
    if rising >= LIMITS["driftMinDays"] and rising * 2 > len(days):
        out["flag"] = "rising"
        out["warning"] = (f"While fasting, glucose rose more than {limit:g} mg/dL an hour on {rising} of {len(days)} days "
                          "(about {:g} on a typical day). That can mean the long-acting dose isn't covering you; "
                          "worth raising with your care team.".format(out["median"]))
    elif falling >= LIMITS["driftMinDays"] and falling * 2 > len(days):
        out["flag"] = "falling"
        out["warning"] = (f"While fasting, glucose fell more than {limit:g} mg/dL an hour on {falling} of {len(days)} days "
                          "(about {:g} on a typical day). That can mean the long-acting dose is more than you need; "
                          "worth raising with your care team.".format(out["median"]))
    return out


def share(events, now):
    """Long-acting as a share of the daily dose, over past days with both kinds logged.

    {"share", "days", "flag": "low" | "high" | None, "warning"}, or None without enough days.
    """
    today = localtime.at(now).date()
    days = {}
    for e in events:
        if e["kind"] == "insulin" and e.get("units") and e["ts"] <= now:
            day = localtime.at(e["ts"]).date()
            if day != today:
                kind = "long" if e.get("insulinType") == "long" else "rapid"
                days.setdefault(day, {"long": 0.0, "rapid": 0.0})[kind] += e["units"]
    full = [d for d in days.values() if d["long"] and d["rapid"]]
    if len(full) < LIMITS["shareMinDays"]:
        return None
    long_total = sum(d["long"] for d in full)
    value = long_total / (long_total + sum(d["rapid"] for d in full))
    out = {"share": round(value, 2), "days": len(full), "flag": None, "warning": None}
    if value < LIMITS["shareMin"]:
        out["flag"] = "low"
        out["warning"] = (f"Long-acting is {round(value * 100)}% of your daily insulin, below the usual "
                          f"{round(LIMITS['shareMin'] * 100)}–{round(LIMITS['shareMax'] * 100)}%: meals and corrections "
                          "may be making up for basal. Worth raising with your care team.")
    elif value > LIMITS["shareMax"]:
        out["flag"] = "high"
        out["warning"] = (f"Long-acting is {round(value * 100)}% of your daily insulin, above the usual "
                          f"{round(LIMITS['shareMin'] * 100)}–{round(LIMITS['shareMax'] * 100)}%, which can raise the "
                          "risk of lows between meals. Worth raising with your care team.")
    return out


def check(readings, events, low, now, exercises=()):
    """Everything above, for GET /basal: {"missed", "drift", "share", "warnings"}."""
    m, d, s = missed(events, now), drift(readings, events, low, now, exercises), share(events, now)
    warnings = [x["warning"] for x in (m, d, s) if x and x.get("warning")]
    return {"missed": m, "drift": d, "share": s, "warnings": warnings}
