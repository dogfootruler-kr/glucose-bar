package co.dnk.glucosebar

import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import java.time.Instant
import java.time.OffsetDateTime
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.time.temporal.ChronoUnit
import java.util.Locale
import kotlin.math.abs
import kotlin.math.roundToInt

/** The server sends ISO-8601 with an offset (`2026-10-22T08:15:00+00:00`), sometimes with microseconds. */
object InstantSerializer : KSerializer<Instant> {
    override val descriptor = PrimitiveSerialDescriptor("Instant", PrimitiveKind.STRING)
    override fun deserialize(decoder: Decoder): Instant = OffsetDateTime.parse(decoder.decodeString()).toInstant()
    override fun serialize(encoder: Encoder, value: Instant) =
        // Whole seconds, like the server: Python before 3.11 only parses 0, 3 or 6 fractional digits.
        encoder.encodeString(DateTimeFormatter.ISO_OFFSET_DATE_TIME.format(value.truncatedTo(ChronoUnit.SECONDS).atOffset(ZoneOffset.UTC)))
}

typealias Time = @Serializable(with = InstantSerializer::class) Instant

@Serializable
data class Reading(
    val mgdl: Int,
    val trend: Int? = null,
    val arrow: String = "?",
    val delta: Int? = null,
    val timestamp: Time,
)

@Serializable
data class Point(val mgdl: Int, val timestamp: Time)

@Serializable
data class Sensor(val serial: String? = null, val activated: Time)

@Serializable
data class Forecast(val slope: Double, val from: Int, val fromTimestamp: Time, val points: List<Point>) {
    /** When the projection reaches `threshold` (falling), if within the forecast horizon. */
    fun crossingBelow(threshold: Int): Pair<Instant, Int>? {
        if (slope >= 0 || from <= threshold) return null
        val minutes = (threshold - from) / slope
        if (minutes > 30) return null
        return fromTimestamp.plusMillis((minutes * 60_000).toLong()) to threshold
    }

    val in30: Int? get() = points.lastOrNull()?.mgdl
}

@Serializable
data class GlucoseEvent(
    val id: Int,
    val timestamp: Time,
    val kind: String,
    val carbs: Double? = null,
    val units: Double? = null,
    val insulinType: String? = null,
    val note: String? = null,
    val photo: String? = null,
    val estimate: MealEstimate? = null,
    val activity: String? = null,
    val minutes: Double? = null,
    val intensity: String? = null,
) {
    val isMeal get() = kind == "meal"
    val isInsulin get() = kind == "insulin"
    val isExercise get() = kind == "exercise"
    val isRapid get() = isInsulin && insulinType != "long"
    val isLong get() = isInsulin && insulinType == "long"
    /** Exercise logged ahead of time that hasn't started yet. */
    val isPlanned get() = isExercise && timestamp > Instant.now()
    val end: Instant get() = timestamp.plusSeconds(((minutes ?: 0.0) * 60).toLong())
    val exerciseActivity get() = Activity.entries.firstOrNull { it.raw == activity } ?: Activity.Other

    val title: String
        get() = when (kind) {
            "meal" -> note ?: "Meal"
            "exercise" -> "${exerciseActivity.label} · ${formatMinutes(minutes ?: 0.0)}"
            else -> "${formatUnits(units ?: 0.0)} u ${if (insulinType == "long") "long-acting" else "rapid"}"
        }

    val label: String
        get() = when (kind) {
            "meal" -> listOfNotNull(note, carbs?.let { "${it.toInt()} g carbs" }).joinToString(" · ")
            "exercise" -> (if (isPlanned) "Planned: " else "") + listOfNotNull(title, intensity, note).joinToString(" · ")
            else -> "${formatUnits(units ?: 0.0)} u ${insulinType ?: "rapid"}" + (note?.let { " · $it" } ?: "")
        }

    /** What the chart shows above the entry's marker. */
    val shortLabel: String
        get() = when (kind) {
            "meal" -> "${(carbs ?: 0.0).toInt()}g"
            "exercise" -> "${(minutes ?: 0.0).toInt()}m"
            else -> "${formatUnits(units ?: 0.0)}u"
        }
}

enum class Activity(val raw: String, val label: String, val emoji: String) {
    Walk("walk", "Walk", "🚶"),
    Run("run", "Run", "🏃"),
    Cycling("cycling", "Cycling", "🚴"),
    Strength("strength", "Strength", "🏋️"),
    Swim("swim", "Swim", "🏊"),
    Sport("sport", "Sport", "🎾"),
    Other("other", "Exercise", "🤸");

    /** What `intensity` looks like for this activity, e.g. "brisk, 5 to 6 km/h" for a moderate walk. */
    fun example(intensity: String): String? = when (this to intensity) {
        Walk to "light" -> "strolling, under 4 km/h"
        Walk to "moderate" -> "brisk, 5 to 6 km/h"
        Walk to "hard" -> "uphill, hiking or 7 km/h and up"
        Run to "light" -> "a very easy jog"
        Run to "moderate" -> "a steady pace you could keep up for an hour"
        Run to "hard" -> "intervals, tempo runs or races"
        Cycling to "light" -> "an easy ride on the flat"
        Cycling to "moderate" -> "a steady commuting pace"
        Cycling to "hard" -> "hills or a fast group ride"
        Strength to "light" -> "light weights, lots of reps"
        Strength to "moderate" -> "working sets with rests between"
        Strength to "hard" -> "heavy lifts close to failure"
        Swim to "light" -> "easy laps with rests"
        Swim to "moderate" -> "steady laps without stopping"
        Swim to "hard" -> "fast sets"
        Sport to "light" -> "a casual knock-about"
        Sport to "moderate" -> "a friendly game"
        Sport to "hard" -> "a competitive match"
        else -> null
    }
}

val intensities = listOf("light", "moderate", "hard")

/** How to tell an intensity apart (the talk test) and what the app does with it. */
fun intensityInfo(intensity: String) = when (intensity) {
    "light" -> "You could chat or sing. Glucose dips a little; alerts stay as usual."
    "moderate" -> "You can talk but not sing; breathing faster, warm. Glucose falls during it, and low alerts come earlier for 4 hours after."
    else -> "Only a few words at a time. Sprints and heavy lifts can push glucose up at first, then it can drop for hours: low alerts come earlier for 6 hours after."
}

@Serializable
data class MealImpact(
    val baseline: Int,
    val peak: Int,
    val rise: Int,
    val minutesToPeak: Int,
    val minutesAboveHigh: Int,
    val minutesToBaseline: Int? = null,
    val score: Int,
    val earlyRise: Int? = null,
    val foodScore: Int? = null,
    /** mg/dL exercise took off glucose in the first 90 minutes, when it was 10 or more. */
    val exerciseEffect: Int? = null,
    val complete: Boolean,
)

/** How the rapid insulin around a meal worked out (see server/dosing.py). */
@Serializable
data class MealDose(
    val units: Double,
    val minutesFromMeal: Int? = null,
    val laterUnits: Double,
    val carbs: Double,
    val sharedWith: Int,
    val suggested: Double? = null,
    val verdict: String? = null,
    val reason: String? = null,
) {
    val verdictLabel: String?
        get() = when (verdict) {
            "ok" -> "Dose about right"
            "tooLittle" -> "Dose too low"
            "tooMuch" -> "Dose too high"
            "none" -> "No insulin logged"
            else -> null
        }
}

/** How much less rapid insulin a meal needs because of exercise (see server/exercise.py). */
@Serializable
data class ExerciseAdjustment(val units: Double, val label: String, val warning: String? = null)

@Serializable
data class DoseSuggestion(
    val units: Double,
    val carbUnits: Double,
    val correctionUnits: Double,
    val trendUnits: Double,
    val activeInsulin: Double,
    val carbsOnBoard: Int,
    val activeDeducted: Double,
    val glucose: Int? = null,
    val target: Int,
    val warning: String? = null,
    val period: String,
    val periodCarbRatio: Double,
    val carbRatio: Double,
    val sensitivity: Int,
    val byTime: Map<String, Period> = emptyMap(),
    val exercise: ExerciseAdjustment? = null,
    val rulesCarbRatio: Double,
    val rulesSensitivity: Int,
    val dailyDose: Double,
    val meals: Int,
    val corrections: Int,
    val days: Double,
    /** Set when Claude adjusted the dose for how similar meals went (POST /dose/history). */
    val formulaUnits: Double? = null,
    val history: History? = null,
) {
    @Serializable
    data class Period(val carbRatio: Double, val meals: Int)

    /** Claude's change to the formula's dose, from past meals of the same food. */
    @Serializable
    data class History(val units: Double, val reason: String, val meals: Int)
}

@Serializable
data class DoseHistoryRequest(
    val carbs: Double, val note: String?, val description: String?, val target: Int, val low: Int, val high: Int,
)

/** Exercise around a meal and how much it lowered glucose over the 3 hours after it. */
@Serializable
data class MealExercise(val items: List<String>, val effect: Int)

@Serializable
data class Meal(
    val id: Int,
    val timestamp: Time,
    val carbs: Double? = null,
    val note: String? = null,
    val photo: String? = null,
    val impact: MealImpact? = null,
    val dose: MealDose? = null,
    val exercise: MealExercise? = null,
) {
    /** The score shown for a meal: how gently glucose rose in the first 90 minutes, which says more
     *  about the food than the later hours, when a wrong dose shows. */
    val score: Int? get() = impact?.let { it.foodScore ?: it.score }
}

/** How glucose responded to one exercise session, during it and in the 12 hours after. */
@Serializable
data class ExerciseImpact(
    val startGlucose: Int? = null,
    val endGlucose: Int? = null,
    val change: Int? = null,
    val expectedDrop: Int,
    val exerciseDrop: Int? = null,
    val lowest: Low? = null,
    val lowAfter: Low? = null,
    val lowDuring: Boolean,
    val inProgress: Boolean,
    val complete: Boolean,
) {
    @Serializable
    data class Low(val mgdl: Int, val timestamp: Time, val minutesAfter: Int? = null)
}

@Serializable
data class Exercise(val id: Int, val impact: ExerciseImpact? = null)

/** Low alerts come earlier for a while after moderate or hard exercise. */
@Serializable
data class PostExercise(val until: Time, val label: String, val raise: Int, val lookahead: Int)

@Serializable
data class MealEstimate(
    val description: String,
    val items: List<Item>,
    val carbs: Double,
    val confidence: String,
    val note: String? = null,
) {
    @Serializable
    data class Item(val name: String, val carbs: Double)
}

@Serializable
data class Summary(val id: Int, val created: Time, val periodStart: Time, val periodEnd: Time, val text: String)

@Serializable
data class SummaryResponse(val summary: Summary? = null, val aiAvailable: Boolean = false)

@Serializable
data class ServerState(
    val reading: Reading? = null,
    val sensor: Sensor? = null,
    val history: List<Point> = emptyList(),
    val forecast: Forecast? = null,
    val events: List<GlucoseEvent> = emptyList(),
    val postExercise: PostExercise? = null,
    val aiAvailable: Boolean = false,
    val error: String? = null,
)

@Serializable
data class Stats(val count: Int, val average: Int, val inRange: Int, val below: Int, val above: Int, val gmi: Double)

@Serializable
data class StatsResponse(val today: Stats? = null, val week: Stats? = null)

/** A new entry, or the fields to change on an existing one (nulls are left out of the JSON). */
@Serializable
data class EventBody(
    val kind: String? = null,
    val timestamp: Time? = null,
    val carbs: Double? = null,
    val units: Double? = null,
    val insulinType: String? = null,
    val activity: String? = null,
    val minutes: Double? = null,
    val intensity: String? = null,
    val note: String? = null,
    val photo: String? = null,
    val mediaType: String? = null,
    val removePhoto: Boolean? = null,
    val estimate: MealEstimate? = null,
    /** Sent as `"carbs": null` to clear the carbs on an existing meal. */
    @kotlinx.serialization.Transient val clearCarbs: Boolean = false,
)

@Serializable
data class ErrorBody(val error: String)

@Serializable
data class EstimateRequest(val photo: String?, val mediaType: String, val text: String?)

/** All user settings, stored in SharedPreferences under the Mac app's keys. Glucose values are always mg/dL. */
data class Settings(
    val serverURL: String = DEFAULT_SERVER,
    val useMmol: Boolean = false,
    val targetLow: Int = 70,
    val targetHigh: Int = 180,
    val showDelta: Boolean = true,
    val showSparkline: Boolean = true,
    val sparklineHours: Int = 2,
    val chartHours: Int = 12,
    val alertsEnabled: Boolean = true,
    val alertLow: Int = 70,
    val alertHigh: Int = 250,
    val alertFastDrop: Boolean = true,
    val alertPredictedLow: Boolean = true,
    val staleMinutes: Int = 20,
    val sensorDays: Int = 14,
    val doseTarget: Int = 120,
) {
    fun format(mgdl: Int) = formatGlucose(mgdl, useMmol)
    val unit get() = if (useMmol) "mmol/L" else "mg/dL"

    companion object {
        const val DEFAULT_SERVER = "http://glucose-work:8765"
    }
}

fun formatGlucose(mgdl: Int, mmol: Boolean): String =
    if (mmol) "%.1f".format(Locale.ROOT, mgdl / 18.0182) else "$mgdl"

fun formatDelta(delta: Int, mmol: Boolean): String {
    val sign = if (delta >= 0) "+" else "−"
    return sign + if (mmol) "%.1f".format(Locale.ROOT, abs(delta) / 18.0182) else "${abs(delta)}"
}

fun formatUnits(u: Double): String = if (u == Math.rint(u)) "${u.toInt()}" else "%.1f".format(Locale.ROOT, u)

fun formatMinutes(m: Double): String {
    val total = m.roundToInt()
    return if (total < 60) "$total min" else "${total / 60} h" + if (total % 60 > 0) " ${total % 60} min" else ""
}

fun String.capitalizedFirst() = replaceFirstChar { it.uppercase() }
