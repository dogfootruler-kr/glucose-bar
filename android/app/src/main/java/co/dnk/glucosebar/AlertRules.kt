package co.dnk.glucosebar

import java.time.Duration
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import kotlin.math.max

/** The alert rules from the Mac app (Alerts.swift), kept free of Android so they can be unit tested. */
enum class Condition {
    Low, High, FastDrop, PredictedLow, Stale;

    /** Lows break through Do Not Disturb; high and no-data alerts don't. */
    val urgent get() = this == Low || this == FastDrop || this == PredictedLow
}

data class Alert(val condition: Condition, val title: String, val body: String)

/** What's wrong right now. For a few hours after moderate or hard exercise, heading-low alerts come earlier. */
fun activeAlerts(
    reading: Reading?,
    forecast: Forecast?,
    postExercise: PostExercise?,
    stale: Boolean,
    staleSince: Instant,
    settings: Settings,
    now: Instant,
    zone: ZoneId = ZoneId.systemDefault(),
): List<Alert> {
    val raise = postExercise?.raise ?: 0
    val lowLimit = settings.alertLow + raise
    val active = linkedMapOf<Condition, Alert>()
    fun add(c: Condition, title: String, body: String) { active[c] = Alert(c, title, body) }

    if (stale) {
        val mins = Duration.between(staleSince, now).toMinutes()
        add(Condition.Stale, "No glucose data",
            if (mins > 600) "No reading received yet." else "No new reading for $mins minutes. Check the sensor and phone.")
    } else if (reading != null) {
        val value = "${settings.format(reading.mgdl)} ${reading.arrow}"
        if (reading.mgdl <= settings.alertLow) {
            add(Condition.Low, "Low glucose: $value", "Below your low alert.")
        } else if (reading.mgdl >= settings.alertHigh) {
            add(Condition.High, "High glucose: $value", "Above your high alert.")
        }
        if (settings.alertFastDrop && (reading.trend ?: 3) in 1..2 && reading.mgdl < 100 + raise && Condition.Low !in active) {
            add(Condition.FastDrop, "Dropping fast: $value", "Glucose is falling quickly.")
        }
        if (settings.alertPredictedLow && Condition.Low !in active && Condition.FastDrop !in active) {
            val because = postExercise?.let { " Alerting earlier after your ${it.label}." } ?: ""
            val hit = forecast?.crossingBelow(lowLimit)
            if (hit != null && Duration.between(now, hit.first) <= Duration.ofMinutes((postExercise?.lookahead ?: 20).toLong())) {
                val mins = max(1, Duration.between(now, hit.first).toMinutes())
                val time = DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT).withZone(zone).format(hit.first)
                add(Condition.PredictedLow, "Heading low: $value",
                    "Projected to reach ${settings.format(hit.second)} in about $mins min ($time).$because")
            } else if (raise > 0 && reading.mgdl <= lowLimit && (forecast?.slope ?: 0.0) < 0) {
                // Already below the raised threshold, so the forecast can't cross it.
                add(Condition.PredictedLow, "Falling after exercise: $value", "Glucose is still dropping.$because")
            }
        }
    }
    return active.values.toList()
}

/** Repeats each alert every 20 minutes while its condition lasts, and forgets it once it clears. */
class AlertThrottle(
    /** When each condition was last posted; kept by the caller so it survives a restart. */
    val lastNotified: MutableMap<Condition, Instant> = mutableMapOf(),
    private val repeat: Duration = Duration.ofMinutes(20),
) {
    /** The alerts to post now. Conditions that cleared are forgotten even while alerts are off or snoozed. */
    fun due(active: List<Alert>, now: Instant, enabled: Boolean, snoozed: Boolean): List<Alert> {
        lastNotified.keys.retainAll(active.map { it.condition }.toSet())
        if (!enabled || snoozed) return emptyList()
        return active.filter { alert ->
            val last = lastNotified[alert.condition]
            (last == null || Duration.between(last, now) > repeat).also { if (it) lastNotified[alert.condition] = now }
        }
    }
}
