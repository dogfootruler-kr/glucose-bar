package co.dnk.glucosebar

import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import java.time.ZoneOffset

class CorrectionAlertTest {
    private val now = Instant.parse("2026-10-22T08:00:00Z")
    private val settings = Settings()
    private val due = CorrectionReminder(due = true, units = 2.5, glucose = 250, high = 180, minutesHigh = 40, repeatMinutes = 120.0)

    private fun reading(mgdl: Int) = Reading(mgdl, 3, "→", null, now)

    private fun alerts(correction: CorrectionReminder?, mgdl: Int = 200, s: Settings = settings, stale: Boolean = false) =
        activeAlerts(reading(mgdl), null, null, stale, now, s, now, ZoneOffset.UTC, correction)

    @Test fun dueReminderIsShown() {
        val a = alerts(due).single { it.condition == Condition.Correction }
        assertEquals("Correction suggested: 2.5 u", a.title)
        assertTrue(a.body.contains("above 180 for 40 min (now 250)"))
        assertTrue(a.body.endsWith("Check before dosing."))
        assertEquals(java.time.Duration.ofMinutes(120), a.repeat)
    }

    @Test fun inTheUsersUnits() {
        val a = alerts(due, s = settings.copy(useMmol = true)).single { it.condition == Condition.Correction }
        assertTrue(a.body.contains("above 10.0 for 40 min (now 13.9)"))
    }

    @Test fun notDueOrOffOrStaleShowsNothing() {
        assertEquals(emptyList<Condition>(), alerts(CorrectionReminder(due = false, reason = "recentInsulin")).map { it.condition })
        assertEquals(emptyList<Condition>(), alerts(due, s = settings.copy(alertCorrection = false)).map { it.condition })
        assertEquals(listOf(Condition.Stale), alerts(due, stale = true).map { it.condition })
        assertEquals(emptyList<Condition>(), alerts(null).map { it.condition })
    }

    @Test fun repeatsEveryTwoHoursNotTwentyMinutes() {
        val throttle = AlertThrottle()
        val active = alerts(due)
        assertEquals(1, throttle.due(active, now, enabled = true, snoozed = false).size)
        assertEquals(0, throttle.due(active, now.plusSeconds(60 * 60), enabled = true, snoozed = false).size)
        assertEquals(1, throttle.due(active, now.plusSeconds(121 * 60), enabled = true, snoozed = false).size)
    }

    @Test fun olderServerHasNoReminder() {
        val state = Json { ignoreUnknownKeys = true }.decodeFromString(ServerState.serializer(), """{"history": []}""")
        assertNull(state.correction)
        val c = Json { ignoreUnknownKeys = true }.decodeFromString(ServerState.serializer(),
            """{"history": [], "correction": {"due": true, "units": 2.5, "glucose": 250, "high": 180, "since": 1.8E9, "minutesHigh": 40,
               "text": "…", "repeatMinutes": 120.0, "alerts": []}}""").correction
        assertEquals(2.5, c!!.units!!, 0.0)
    }
}
