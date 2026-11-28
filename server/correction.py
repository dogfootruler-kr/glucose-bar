"""When to suggest a correction dose: glucose has stayed high, isn't coming down, and nothing logged
explains it or is already dealing with it.

The server decides (one rule for every app); the apps only show it. The dose comes from
dosing.suggest with no carbs, so its safety rules all apply: insulin still active is taken off,
the per-dose cap, no insulin when heading low. A reminder is only ever a suggestion to check.

This is an estimate from self-logged data, not medical advice.
"""
import dosing

LIMITS = {
    "enabled": True,
    "sustainedMinutes": 30,       # how long glucose has to stay above high
    "minUnits": 1.0,              # smallest suggested correction worth a reminder
    "rapidCooldownMinutes": 180,  # no reminder this soon after any logged rapid dose
    "repeatMinutes": 120,         # apps remind again at most this often while it lasts
    "fallingSlope": -0.5,         # mg/dL per minute; falling faster than this means it's coming down
    "maxAgeMinutes": 15,          # the latest reading must be this recent
}
GAP = 20 * 60   # readings further apart than this break a high stretch


def configure(cfg):
    """Override LIMITS from config.json's "correctionAlerts" object (ValueError for unknown keys or bad values)."""
    for key, value in (cfg or {}).items():
        if key not in LIMITS:
            raise ValueError(f'unknown "correctionAlerts" setting "{key}" (known: {", ".join(LIMITS)})')
        if key == "enabled":
            if not isinstance(value, bool):
                raise ValueError('"correctionAlerts.enabled" must be true or false')
            LIMITS[key] = value
            continue
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            raise ValueError(f'"correctionAlerts.{key}" must be a number')
        if key != "fallingSlope" and value <= 0:
            raise ValueError(f'"correctionAlerts.{key}" must be positive')
        if key == "fallingSlope" and value > 0:
            raise ValueError('"correctionAlerts.fallingSlope" must be zero or negative (mg/dL per minute)')
        LIMITS[key] = float(value)
    if LIMITS["sustainedMinutes"] < 15:
        raise ValueError('"correctionAlerts.sustainedMinutes" must be at least 15')
    if LIMITS["minUnits"] < 0.5:
        raise ValueError('"correctionAlerts.minUnits" must be at least 0.5')


def high_since(readings, high):
    """Start of the stretch above `high` that the latest reading is part of, or None."""
    since = None
    later = None
    for ts, v in reversed(readings):
        if v <= high or (later is not None and later - ts > GAP):
            break
        since, later = ts, ts
    return since


def _off(reason, **extra):
    return {"due": False, "reason": reason, **extra}


def check(readings, slope, events, now, high, suggest):
    """Whether to remind about a correction now.

    readings: [(ts, mgdl)] sorted, covering at least sustainedMinutes; slope: mg/dL per minute from the
    forecast (None if unknown); events: meals and insulin from the last 8 h; suggest(): the dose suggestion
    for no carbs (dosing.suggest through the server), called only once everything else says yes.

    {"due": bool, "reason": why not (when not due), and when due "units", "glucose", "high", "since",
     "minutesHigh", "title", "text", "repeatMinutes", "alerts" (the suggestion's warnings)}
    """
    if not LIMITS["enabled"]:
        return _off("off")
    if not readings or now - readings[-1][0] > LIMITS["maxAgeMinutes"] * 60:
        return _off("noRecentReading")
    ts, glucose = readings[-1]
    since = high_since(readings, high)
    if since is None:
        return _off("notHigh")
    minutes = (ts - since) / 60
    if minutes < LIMITS["sustainedMinutes"]:
        return _off("notHighLongEnough", minutesHigh=round(minutes))
    if slope is None:
        return _off("noTrend")
    if slope < LIMITS["fallingSlope"]:
        return _off("falling")
    cooldown = LIMITS["rapidCooldownMinutes"] * 60
    if any(e["kind"] == "insulin" and (e.get("insulinType") or "rapid") == "rapid" and e.get("units")
           and 0 <= now - e["ts"] <= cooldown for e in events):
        return _off("recentInsulin")
    if dosing._cob(dosing._meals(events), now) >= 1:
        return _off("carbsOnBoard")
    s = suggest()
    if s is None:
        return _off("noDoseParams")
    if s["units"] < LIMITS["minUnits"]:
        return _off("smallDose", units=s["units"])
    units = s["units"]
    capped = " (capped)" if s.get("capped") else ""
    return {
        "due": True,
        "units": units,
        "glucose": glucose,
        "high": high,
        "since": since,
        "minutesHigh": round(minutes),
        "title": f"High for {round(minutes)} min: {glucose}",
        "text": f"Glucose has been above {high} for {round(minutes)} min and isn't coming down. "
                f"Suggested correction: {dosing._fmt(units)} u{capped}, if you haven't taken insulin you didn't log. "
                "Check before dosing.",
        "repeatMinutes": LIMITS["repeatMinutes"],
        "alerts": s.get("alerts", []),
    }
