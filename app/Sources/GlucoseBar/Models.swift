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

struct ServerState: Decodable {
    let reading: Reading?
    let sensor: Sensor?
    let history: [Point]
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
