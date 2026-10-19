import Foundation

struct Reading: Decodable {
    let mgdl: Int
    let trend: Int?
    let arrow: String
    let delta: Int?
    let timestamp: Date
}

struct Point: Decodable, Identifiable {
    let mgdl: Int
    let timestamp: Date
    var id: Date { timestamp }
}

struct Sensor: Decodable {
    let serial: String?
    let activated: Date
}

struct Forecast: Decodable {
    let slope: Double
    let from: Int
    let fromTimestamp: Date
    let points: [Point]

    /// When the projection reaches `threshold` (falling), if within the forecast horizon.
    func crossing(below threshold: Int) -> (date: Date, mgdl: Int)? {
        guard slope < 0, from > threshold else { return nil }
        let minutes = Double(threshold - from) / slope
        guard minutes <= 30 else { return nil }
        return (fromTimestamp.addingTimeInterval(minutes * 60), threshold)
    }

    var in30: Int? { points.last?.mgdl }
}

struct GlucoseEvent: Decodable, Identifiable, Hashable {
    let id: Int
    let timestamp: Date
    let kind: String
    let carbs: Double?
    let units: Double?
    let insulinType: String?
    let note: String?
    let photo: String?
    let estimate: MealEstimate?

    var isMeal: Bool { kind == "meal" }
    var isRapid: Bool { !isMeal && insulinType != "long" }

    var title: String {
        if isMeal { return note ?? "Meal" }
        return "\(formatUnits(units ?? 0)) u \(insulinType == "long" ? "long-acting" : "rapid")"
    }

    var label: String {
        if isMeal {
            return [note, carbs.map { "\(Int($0)) g carbs" }].compactMap { $0 }.joined(separator: " · ")
        }
        return "\(formatUnits(units ?? 0)) u \(insulinType ?? "rapid")" + (note.map { " · \($0)" } ?? "")
    }
}

struct MealImpact: Decodable {
    let baseline: Int
    let peak: Int
    let rise: Int
    let minutesToPeak: Int
    let minutesAboveHigh: Int
    let minutesToBaseline: Int?
    let score: Int
    let earlyRise: Int?
    let foodScore: Int?
    let complete: Bool
}

/// How the rapid insulin around a meal worked out (see server/dosing.py).
struct MealDose: Decodable, Hashable {
    let units: Double
    let minutesFromMeal: Int?
    let laterUnits: Double
    let carbs: Double
    let sharedWith: Int
    let suggested: Double?
    let verdict: String?
    let reason: String?

    var verdictLabel: String? {
        switch verdict {
        case "ok": "Dose about right"
        case "tooLittle": "Dose too low"
        case "tooMuch": "Dose too high"
        case "none": "No insulin logged"
        default: nil
        }
    }
}

struct DoseSuggestion: Decodable {
    struct Period: Decodable { let carbRatio: Double; let meals: Int }
    let units: Double
    let carbUnits: Double
    let correctionUnits: Double
    let trendUnits: Double
    let activeInsulin: Double
    let carbsOnBoard: Int
    let activeDeducted: Double
    let glucose: Int?
    let target: Int
    let warning: String?
    let period: String
    let periodCarbRatio: Double
    let carbRatio: Double
    let sensitivity: Int
    let byTime: [String: Period]
    let rulesCarbRatio: Double
    let rulesSensitivity: Int
    let dailyDose: Double
    let meals: Int
    let corrections: Int
    let days: Double
}

extension MealImpact: Hashable {}

struct Meal: Decodable, Identifiable, Hashable {
    let id: Int
    let timestamp: Date
    let carbs: Double?
    let note: String?
    let photo: String?
    let impact: MealImpact?
    let dose: MealDose?

    /// The score shown for a meal: how gently glucose rose in the first 90 minutes, which says more
    /// about the food than the later hours, when a wrong dose shows.
    var score: Int? { impact.map { $0.foodScore ?? $0.score } }
}

struct MealEstimate: Codable, Hashable {
    struct Item: Codable, Hashable { let name: String; let carbs: Double }
    let description: String
    let items: [Item]
    let carbs: Double
    let confidence: String
    let note: String?
}

struct Summary: Decodable {
    let id: Int
    let created: Date
    let periodStart: Date
    let periodEnd: Date
    let text: String
}

struct SummaryResponse: Decodable {
    let summary: Summary?
    let aiAvailable: Bool
}

struct ServerState: Decodable {
    let reading: Reading?
    let sensor: Sensor?
    let history: [Point]
    let forecast: Forecast?
    let events: [GlucoseEvent]?
    let aiAvailable: Bool?
    let error: String?
}

struct Stats: Decodable {
    let count: Int
    let average: Int
    let inRange: Int
    let below: Int
    let above: Int
    let gmi: Double
}

struct StatsResponse: Decodable {
    let today: Stats?
    let week: Stats?
}

/// All user settings, stored in UserDefaults. Glucose values are always mg/dL.
enum SettingDefaults {
    static let values: [String: Any] = [
        "useMmol": false,
        "targetLow": 70, "targetHigh": 180,
        "showDelta": true,
        "showSparkline": true, "sparklineHours": 2,
        "dotWhenInRange": false,
        "chartHours": 12,
        "alertsEnabled": true,
        "alertLow": 70, "alertHigh": 250,
        "alertFastDrop": true,
        "alertPredictedLow": true,
        "staleMinutes": 20,
        "sensorDays": 14,
        "doseTarget": 120,
    ]
}

func formatGlucose(_ mgdl: Int, mmol: Bool) -> String {
    mmol ? String(format: "%.1f", Double(mgdl) / 18.0182) : "\(mgdl)"
}

func formatDelta(_ delta: Int, mmol: Bool) -> String {
    let sign = delta >= 0 ? "+" : "−"
    return sign + (mmol ? String(format: "%.1f", Double(abs(delta)) / 18.0182) : "\(abs(delta))")
}

func formatUnits(_ u: Double) -> String {
    u == u.rounded() ? String(Int(u)) : String(format: "%.1f", u)
}
