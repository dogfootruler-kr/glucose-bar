import AppKit
import SwiftUI

@MainActor
final class GlucoseStore: ObservableObject {
    static let server = URL(string: "http://127.0.0.1:8765")!

    @Published var state: ServerState?
    @Published var stats: StatsResponse?
    @Published var fetchError: String?
    @Published var meals: [Meal] = []
    @Published var recentEvents: [GlucoseEvent] = []
    @Published var summary: Summary?
    @Published var aiAvailable = false
    @Published var generatingSummary = false
    private var lastSummaryFetch = Date.distantPast
    @Published private(set) var lastSuccess = Date()
    private let launched = Date()

    let alerts = AlertManager()
    private let defaults = UserDefaults.standard
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init() {
        defaults.register(defaults: SettingDefaults.values)
        Task {
            while true {
                await refresh()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    func refresh() async {
        do {
            let hours = max(defaults.integer(forKey: "chartHours"), 3)
            state = try await get("/glucose?hours=\(hours)")
            stats = try await get("/stats?low=\(targetLow)&high=\(targetHigh)")
            meals = try await get("/meals?days=30&high=\(targetHigh)")
            recentEvents = try await get("/events?hours=24")
            aiAvailable = state?.aiAvailable ?? false
            if Date().timeIntervalSince(lastSummaryFetch) > 600 { await refreshSummary() }
            fetchError = nil
            lastSuccess = Date()
        } catch {
            fetchError = "Server unreachable"
        }
        alerts.evaluate(reading: reading, forecast: state?.forecast, stale: isStale, staleSince: staleSince)
    }

    func refreshSummary() async {
        guard let r: SummaryResponse = try? await get("/summary") else { return }
        lastSummaryFetch = Date()
        let seen = defaults.integer(forKey: "lastSummarySeen")
        if let s = r.summary, s.id != seen {
            if seen != 0 { alerts.post(id: "summary", title: "Your weekly glucose summary is ready", body: "Open GlucoseBar to read it.") }
            defaults.set(s.id, forKey: "lastSummarySeen")
        }
        summary = r.summary
        aiAvailable = r.aiAvailable
    }

    func generateSummary() async {
        generatingSummary = true
        defer { generatingSummary = false }
        do {
            summary = try await send("POST", "/summary/generate?low=\(targetLow)&high=\(targetHigh)", body: [String: String]())
            defaults.set(summary?.id ?? 0, forKey: "lastSummarySeen")
        } catch {
            fetchError = error.localizedDescription
        }
    }

    // MARK: events

    var events: [GlucoseEvent] { state?.events ?? [] }

    func insulinToday() -> (rapid: Double, long: Double) {
        let start = Calendar.current.startOfDay(for: Date())
        var rapid = 0.0, long = 0.0
        for e in recentEvents where !e.isMeal && e.timestamp >= start {
            if e.insulinType == "long" { long += e.units ?? 0 } else { rapid += e.units ?? 0 }
        }
        return (rapid, long)
    }

    struct NewEvent: Encodable {
        var kind: String
        var timestamp: Date
        var carbs: Double?
        var units: Double?
        var insulinType: String?
        var note: String?
        var photo: String?
        var mediaType: String?
        var estimate: MealEstimate?
    }

    func addEvent(_ event: NewEvent) async throws {
        let _: GlucoseEvent = try await send("POST", "/events", body: event)
        await refresh()
    }

    func deleteEvent(_ id: Int) async {
        var req = URLRequest(url: URL(string: "/events/\(id)", relativeTo: Self.server)!)
        req.httpMethod = "DELETE"
        _ = try? await URLSession.shared.data(for: req)
        await refresh()
    }

    struct EstimateRequest: Encodable { let photo: String?; let mediaType: String; let text: String? }

    func estimateMeal(photoJPEG: Data?, text: String?) async throws -> MealEstimate {
        try await send("POST", "/meals/estimate",
                       body: EstimateRequest(photo: photoJPEG?.base64EncodedString(), mediaType: "image/jpeg", text: text))
    }

    struct ServerError: LocalizedError, Decodable {
        let error: String
        var errorDescription: String? { error }
    }

    private func send<B: Encodable, T: Decodable>(_ method: String, _ path: String, body: B) async throws -> T {
        var req = URLRequest(url: URL(string: path, relativeTo: Self.server)!)
        req.httpMethod = method
        req.timeoutInterval = 180
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        req.httpBody = try encoder.encode(body)
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw (try? decoder.decode(ServerError.self, from: data)) ?? ServerError(error: "Server error \(http.statusCode)")
        }
        return try decoder.decode(T.self, from: data)
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        let (data, _) = try await URLSession.shared.data(from: URL(string: path, relativeTo: Self.server)!)
        return try decoder.decode(T.self, from: data)
    }

    // MARK: derived values

    var reading: Reading? { state?.reading }
    var useMmol: Bool { defaults.bool(forKey: "useMmol") }
    var targetLow: Int { defaults.integer(forKey: "targetLow") }
    var targetHigh: Int { defaults.integer(forKey: "targetHigh") }

    /// When data stopped arriving: the last reading, or the last successful server contact if earlier.
    var staleSince: Date {
        min(reading?.timestamp ?? launched, fetchError == nil ? .distantFuture : lastSuccess)
    }

    var isStale: Bool {
        Date().timeIntervalSince(staleSince) > Double(defaults.integer(forKey: "staleMinutes")) * 60
    }

    var isInRange: Bool {
        guard let r = reading else { return false }
        return (targetLow...targetHigh).contains(r.mgdl)
    }

    func format(_ mgdl: Int) -> String { formatGlucose(mgdl, mmol: useMmol) }

    var title: String {
        guard let r = reading else { return "– –" }
        var t = "\(format(r.mgdl)) \(r.arrow)"
        if defaults.bool(forKey: "showDelta"), let d = r.delta { t += " \(formatDelta(d, mmol: useMmol))" }
        return t + (isStale ? " ⚠︎" : "")
    }

    var color: Color {
        guard let r = reading, !isStale else { return .secondary }
        if r.mgdl < targetLow { return .red }
        if r.mgdl > targetHigh { return .orange }
        return .green
    }

    var sensorEnds: Date? {
        state?.sensor.map { $0.activated.addingTimeInterval(Double(defaults.integer(forKey: "sensorDays")) * 86400) }
    }

    func history(lastHours hours: Double) -> [Point] {
        let since = Date().addingTimeInterval(-hours * 3600)
        return (state?.history ?? []).filter { $0.timestamp >= since }
    }

    // MARK: actions

    func exportCSV() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "glucose-\(Date().formatted(.iso8601.year().month().day())).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: URL(string: "/export.csv", relativeTo: Self.server)!)
                try data.write(to: dest)
            } catch {
                fetchError = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    func openWebPage(_ fragment: String = "") {
        NSWorkspace.shared.open(URL(string: "/" + fragment, relativeTo: Self.server)!)
    }
}
