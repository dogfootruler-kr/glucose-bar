package co.dnk.glucosebar

import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import java.time.ZoneOffset

class AlertRulesTest {
    private val now = Instant.parse("2026-10-22T08:00:00Z")
    private val settings = Settings()

    private fun reading(mgdl: Int, trend: Int? = 3) = Reading(mgdl, trend, "→", null, now)

    private fun forecast(from: Int, slope: Double) =
        Forecast(slope, from, now, (1..6).map { Point((from + slope * it * 5).toInt(), now.plusSeconds(it * 300L)) })

    private fun alerts(
        reading: Reading?, forecast: Forecast? = null, post: PostExercise? = null, stale: Boolean = false, s: Settings = settings,
    ) = activeAlerts(reading, forecast, post, stale, now.minusSeconds(25 * 60), s, now, ZoneOffset.UTC).map { it.condition }

    @Test fun inRangeIsQuiet() = assertEquals(emptyList<Condition>(), alerts(reading(120)))

    @Test fun lowAtTheThreshold() = assertEquals(listOf(Condition.Low), alerts(reading(70, trend = 1), forecast(70, -2.0)))

    @Test fun high() = assertEquals(listOf(Condition.High), alerts(reading(250)))

    @Test fun fastDropOnlyBelow100() {
        assertEquals(listOf(Condition.FastDrop), alerts(reading(95, trend = 1)))
        assertEquals(emptyList<Condition>(), alerts(reading(105, trend = 2)))
        assertEquals(emptyList<Condition>(), alerts(reading(95, trend = null)))
    }

    @Test fun headingLowWithin20Minutes() {
        assertEquals(listOf(Condition.PredictedLow), alerts(reading(100), forecast(100, -2.0)))  // 70 in 15 min
        assertEquals(emptyList<Condition>(), alerts(reading(120), forecast(120, -2.0)))          // 25 min away
    }

    @Test fun exerciseRaisesTheLowLimitAndLooksFurtherAhead() {
        val post = PostExercise(now.plusSeconds(3600), "45 min moderate run", raise = 15, lookahead = 30)
        assertEquals(listOf(Condition.PredictedLow), alerts(reading(120), forecast(120, -1.5), post))  // 85 in 23 min
        assertEquals(listOf(Condition.FastDrop), alerts(reading(110, trend = 2), post = post))          // below 115
        // Already under the raised limit, still falling.
        val falling = activeAlerts(reading(80), forecast(80, -0.5), post, false, now, settings, now, ZoneOffset.UTC)
        assertEquals("Falling after exercise: 80 →", falling.single().title)
    }

    @Test fun staleReplacesEverythingElse() {
        val stale = activeAlerts(reading(60), null, null, true, now.minusSeconds(25 * 60), settings, now)
        assertEquals(listOf(Condition.Stale), stale.map { it.condition })
        assertTrue(stale.single().body.startsWith("No new reading for 25 minutes"))
    }

    @Test fun switchesRespected() {
        val off = settings.copy(alertFastDrop = false, alertPredictedLow = false)
        assertEquals(emptyList<Condition>(), alerts(reading(95, trend = 1), forecast(95, -3.0), s = off))
    }

    @Test fun crossing() {
        assertNull(forecast(100, 1.0).crossingBelow(70))
        assertNull(forecast(60, -1.0).crossingBelow(70))
        assertEquals(now.plusSeconds(15 * 60), forecast(100, -2.0).crossingBelow(70)!!.first)
    }

    @Test fun throttleRepeatsEvery20MinutesAndForgetsClearedConditions() {
        val throttle = AlertThrottle()
        val low = listOf(Alert(Condition.Low, "Low", ""))
        assertEquals(1, throttle.due(low, now, enabled = true, snoozed = false).size)
        assertEquals(0, throttle.due(low, now.plusSeconds(10 * 60), enabled = true, snoozed = false).size)
        assertEquals(1, throttle.due(low, now.plusSeconds(21 * 60), enabled = true, snoozed = false).size)
        throttle.due(emptyList(), now.plusSeconds(22 * 60), enabled = true, snoozed = false)
        assertEquals(1, throttle.due(low, now.plusSeconds(23 * 60), enabled = true, snoozed = false).size)
        assertEquals(0, throttle.due(low, now.plusSeconds(60 * 60), enabled = true, snoozed = true).size)
    }

    @Test fun formatting() {
        assertEquals("6.7", formatGlucose(120, mmol = true))
        assertEquals("−4", formatDelta(-4, mmol = false))
        assertEquals("1.5", formatUnits(1.5))
        assertEquals("2", formatUnits(2.0))
        assertEquals("1 h 30 min", formatMinutes(90.0))
    }

    @Test fun decodesServerTimestamps() {
        val r = Json { ignoreUnknownKeys = true }.decodeFromString(Reading.serializer(),
            """{"mgdl":155,"trend":3,"arrow":"→","delta":4,"timestamp":"2026-10-22T03:42:46.123456+00:00","isHigh":false}""")
        assertEquals(Instant.parse("2026-10-22T03:42:46.123456Z"), r.timestamp)
    }
}
