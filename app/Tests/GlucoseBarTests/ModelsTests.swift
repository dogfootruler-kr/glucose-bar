import XCTest
@testable import GlucoseBar

final class FormattingTests: XCTestCase {
    func testUnits() {
        XCTAssertEqual(formatUnits(5), "5")
        XCTAssertEqual(formatUnits(2.5), "2.5")
        XCTAssertEqual(formatUnits(0), "0")
    }

    func testGlucose() {
        XCTAssertEqual(formatGlucose(120, mmol: false), "120")
        XCTAssertEqual(formatGlucose(180, mmol: true), "10.0")
        XCTAssertEqual(formatGlucose(70, mmol: true), "3.9")
    }

    func testDelta() {
        XCTAssertEqual(formatDelta(5, mmol: false), "+5")
        XCTAssertEqual(formatDelta(-9, mmol: false), "−9")
        XCTAssertEqual(formatDelta(-18, mmol: true), "−1.0")
    }

    func testMinutes() {
        XCTAssertEqual(formatMinutes(45), "45 min")
        XCTAssertEqual(formatMinutes(60), "1 h")
        XCTAssertEqual(formatMinutes(95), "1 h 35 min")
    }

    func testCapitalizedFirst() {
        XCTAssertEqual("walk".capitalizedFirst, "Walk")
        XCTAssertEqual("".capitalizedFirst, "")
    }
}

final class DoseSuggestionTests: XCTestCase {
    private func suggestion(_ extra: String = "", exercise: String = "null") throws -> DoseSuggestion {
        let json = """
        {"units": 10, "carbUnits": 60, "correctionUnits": 4.6, "trendUnits": 0, "activeInsulin": 0,
         "carbsOnBoard": 0, "activeDeducted": 0, "glucose": 350, "target": 120,
         "warning": "Capped at 10 u. No long-acting insulin logged in the last 30 h.",
         "period": "midday", "periodCarbRatio": 10, "carbRatio": 10, "sensitivity": 50,
         "byTime": {"midday": {"carbRatio": 10, "meals": 3}}, "exercise": \(exercise),
         "rulesCarbRatio": 12.5, "rulesSensitivity": 45, "dailyDose": 40, "meals": 12, "corrections": 2, "days": 30
         \(extra)}
        """
        return try JSONDecoder().decode(DoseSuggestion.self, from: Data(json.utf8))
    }

    func testOlderServerWithoutAlertsStillShowsTheWarning() throws {
        let s = try suggestion()
        XCTAssertNil(s.alerts)
        XCTAssertNil(s.capped)
        XCTAssertEqual(s.shownAlerts.map(\.kind), ["other"])
        XCTAssertEqual(s.shownAlerts.first?.text, s.warning)
    }

    func testAlertsAreShownMostSeriousFirst() throws {
        let s = try suggestion("""
            , "capped": true, "maxUnits": 10, "alerts": [
              {"kind": "noGlucose", "text": "No recent glucose reading."},
              {"kind": "capped", "text": "Capped at 10 u."},
              {"kind": "headingLow", "text": "You're heading low."}]
            """, exercise: #"{"units": 1, "label": "30 min moderate walk", "warning": "Keep fast carbs to hand."}"#)
        XCTAssertEqual(s.capped, true)
        XCTAssertEqual(s.maxUnits, 10)
        XCTAssertEqual(s.shownAlerts.map(\.kind), ["headingLow", "capped", "exercise", "noGlucose"])
    }

    func testAlertPresentation() {
        let low = DoseAlert(kind: "headingLow", text: "")
        XCTAssertEqual(low.level, .danger)
        XCTAssertEqual(low.title, "Heading low")
        XCTAssertEqual(DoseAlert(kind: "belowLow", text: "").level, .danger)
        XCTAssertEqual(DoseAlert(kind: "capped", text: "").title, "Dose capped")
        XCTAssertEqual(DoseAlert(kind: "missedLong", text: "").level, .caution)
        XCTAssertEqual(DoseAlert(kind: "missedLong", text: "").symbol, "syringe.fill")
        XCTAssertEqual(DoseAlert(kind: "noGlucose", text: "").level, .info)
        XCTAssertNil(DoseAlert(kind: "somethingNew", text: "").title)
    }
}
