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

struct GlucoseEvent: Decodable, Identifiable {
    let id: Int
    let timestamp: Date
    let kind: String
    let carbs: Double?
    let units: Double?
    let insulinType: String?
    let note: String?
    let photo: String?

    var isMeal: Bool { kind == "meal" }

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
    let complete: Bool
}

struct Meal: Decodable, Identifiable {
    let id: Int
    let timestamp: Date
    let carbs: Double?
    let note: String?
    let photo: String?
    let impact: MealImpact?
}

struct MealEstimate: Codable {
    struct Item: Codable { let name: String; let carbs: Double }
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
