import SwiftUI

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
    let activity: String?
    let minutes: Double?
    let intensity: String?

    var isMeal: Bool { kind == "meal" }
    var isInsulin: Bool { kind == "insulin" }
    var isExercise: Bool { kind == "exercise" }
    var isRapid: Bool { isInsulin && insulinType != "long" }
    var isLong: Bool { isInsulin && insulinType == "long" }
    /// Exercise logged ahead of time that hasn't started yet.
    var isPlanned: Bool { isExercise && timestamp > Date() }
    var end: Date { timestamp.addingTimeInterval((minutes ?? 0) * 60) }
    var exerciseActivity: Activity { Activity(rawValue: activity ?? "") ?? .other }

    var title: String {
        switch kind {
        case "meal": note ?? "Meal"
        case "exercise": "\(exerciseActivity.name) · \(formatMinutes(minutes ?? 0))"
        default: "\(formatUnits(units ?? 0)) u \(insulinType == "long" ? "long-acting" : "rapid")"
        }
    }

    var label: String {
        switch kind {
        case "meal":
            [note, carbs.map { "\(Int($0)) g carbs" }].compactMap { $0 }.joined(separator: " · ")
        case "exercise":
            (isPlanned ? "Planned: " : "") + [title, intensity, note].compactMap { $0 }.joined(separator: " · ")
        default:
            "\(formatUnits(units ?? 0)) u \(insulinType ?? "rapid")" + (note.map { " · \($0)" } ?? "")
        }
    }

    /// What the chart shows above the entry's marker.
    var shortLabel: String {
        switch kind {
        case "meal": "\(Int(carbs ?? 0))g"
        case "exercise": "\(Int(minutes ?? 0))m"
        default: "\(formatUnits(units ?? 0))u"
        }
    }

    var symbol: String { isMeal ? "fork.knife" : isExercise ? exerciseActivity.symbol : "syringe.fill" }
    var tint: Color { isMeal ? .orange : isExercise ? .teal : isRapid ? .purple : .indigo }
}

enum Activity: String, CaseIterable {
    case walk, run, cycling, strength, swim, sport, other

    var name: String {
        switch self {
        case .strength: "Strength"
        case .other: "Exercise"
        default: rawValue.capitalized
        }
    }

    var symbol: String {
        switch self {
        case .walk: "figure.walk"
        case .run: "figure.run"
        case .cycling: "figure.outdoor.cycle"
        case .strength: "dumbbell.fill"
        case .swim: "figure.pool.swim"
        case .sport: "figure.tennis"
        case .other: "figure.mixed.cardio"
        }
    }
}

let intensities = ["light", "moderate", "hard"]

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
    /// mg/dL exercise took off glucose in the first 90 minutes, when it was 10 or more.
    let exerciseEffect: Int?
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
    let exercise: ExerciseAdjustment?
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
    let exercise: MealExercise?

    /// The score shown for a meal: how gently glucose rose in the first 90 minutes, which says more
    /// about the food than the later hours, when a wrong dose shows.
    var score: Int? { impact.map { $0.foodScore ?? $0.score } }
}

/// Exercise around a meal and how much it lowered glucose over the 3 hours after it.
struct MealExercise: Decodable, Hashable {
    let items: [String]
    let effect: Int
}

/// How much less rapid insulin a meal needs because of exercise (see server/exercise.py).
struct ExerciseAdjustment: Decodable {
    let units: Double
    let label: String
    let warning: String?
}

/// How glucose responded to one exercise session, during it and in the 12 hours after.
struct ExerciseImpact: Decodable, Hashable {
    struct Low: Decodable, Hashable {
        let mgdl: Int
        let timestamp: Date
        let minutesAfter: Int?  // lowAfter only
    }
    let startGlucose: Int?
    let endGlucose: Int?
    let change: Int?
    let expectedDrop: Int
    let exerciseDrop: Int?
    let lowest: Low?
    let lowAfter: Low?
    let lowDuring: Bool
    let inProgress: Bool
    let complete: Bool
}

struct Exercise: Decodable, Identifiable {
    let id: Int
    let impact: ExerciseImpact?
}

/// Low alerts come earlier for a while after moderate or hard exercise.
struct PostExercise: Decodable {
    let until: Date
    let label: String
    let raise: Int
    let lookahead: Int
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
    let postExercise: PostExercise?
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

func formatMinutes(_ m: Double) -> String {
    let m = Int(m.rounded())
    return m < 60 ? "\(m) min" : "\(m / 60) h" + (m % 60 > 0 ? " \(m % 60) min" : "")
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
