package co.dnk.glucosebar

import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class DoseAlertsTest {
    private val json = Json { ignoreUnknownKeys = true; explicitNulls = false }

    private fun suggestion(extra: String = "", exercise: String = "null") = json.decodeFromString(
        DoseSuggestion.serializer(),
        """
        {"units": 10, "carbUnits": 60, "correctionUnits": 4.6, "trendUnits": 0, "activeInsulin": 0,
         "carbsOnBoard": 0, "activeDeducted": 0, "glucose": 350, "target": 120,
         "warning": "Capped at 10 u.", "period": "midday", "periodCarbRatio": 10, "carbRatio": 10,
         "sensitivity": 50, "byTime": {"midday": {"carbRatio": 10, "meals": 3}}, "exercise": $exercise,
         "rulesCarbRatio": 12.5, "rulesSensitivity": 45, "dailyDose": 40, "meals": 12, "corrections": 2,
         "days": 30, "longActing": null, "predicted": 300 $extra}
        """,
    )

    @Test fun olderServerStillShowsTheWarning() {
        val s = suggestion()
        assertNull(s.alerts)
        assertEquals(listOf(DoseAlert("other", "Capped at 10 u.")), s.shownAlerts)
    }

    @Test fun alertsMostSeriousFirst() {
        val s = suggestion(
            """, "capped": true, "maxUnits": 10, "alerts": [
                {"kind": "noGlucose", "text": "No recent glucose reading."},
                {"kind": "capped", "text": "Capped at 10 u."},
                {"kind": "headingLow", "text": "You're heading low."}]""",
            """{"units": 1, "label": "30 min moderate walk", "warning": "Keep fast carbs to hand."}""",
        )
        assertEquals(true, s.capped)
        assertEquals(10.0, s.maxUnits!!, 0.0)
        assertEquals(listOf("headingLow", "capped", "exercise", "noGlucose"), s.shownAlerts.map { it.kind })
    }

    @Test fun presentation() {
        assertEquals(DoseAlert.Level.Danger, DoseAlert("belowLow", "").level)
        assertEquals("Heading low", DoseAlert("headingLow", "").title)
        assertEquals(DoseAlert.Level.Caution, DoseAlert("missedLong", "").level)
        assertEquals("Long-acting not logged", DoseAlert("missedLong", "").title)
        assertEquals(DoseAlert.Level.Info, DoseAlert("noGlucose", "").level)
        assertNull(DoseAlert("somethingNew", "").title)
    }
}
