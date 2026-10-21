import AppKit
import SwiftUI

@MainActor
final class GlucoseStore: ObservableObject {
    static let localServer = "http://127.0.0.1:8765"

    /// The server this app reads from: the local one, or another Mac's over Tailscale.
    static var server: URL {
        let text = UserDefaults.standard.string(forKey: "serverURL")?.trimmingCharacters(in: .whitespaces) ?? ""
        return URL(string: text.isEmpty ? localServer : text) ?? URL(string: localServer)!
    }

    static var isRemote: Bool { !["127.0.0.1", "localhost"].contains(server.host() ?? "") }

    @Published var state: ServerState?
    @Published var stats: StatsResponse?
    @Published var fetchError: String?
    @Published var meals: [Meal] = []
    @Published var sessions: [Exercise] = []
    /// Meals, insulin and exercise from the last 30 days (and exercise planned ahead), oldest first.
    @Published var entries: [GlucoseEvent] = []
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
            meals = try await get("/meals?days=30&low=\(targetLow)&high=\(targetHigh)")
            entries = try await get("/events?hours=720")
            sessions = (try? await get("/exercise?days=30&low=\(targetLow)")) ?? []  // older servers don't have it
            aiAvailable = state?.aiAvailable ?? false
            if Date().timeIntervalSince(lastSummaryFetch) > 600 { await refreshSummary() }
            fetchError = nil
            lastSuccess = Date()
        } catch {
            fetchError = "Server unreachable"
        }
        alerts.evaluate(reading: reading, forecast: state?.forecast, postExercise: postExercise, stale: isStale, staleSince: staleSince)
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
        for e in entries where e.isInsulin && e.timestamp >= start {
            if e.insulinType == "long" { long += e.units ?? 0 } else { rapid += e.units ?? 0 }
        }
        return (rapid, long)
    }

    /// Minutes of exercise done today, and the next planned session.
    func exerciseToday() -> (minutes: Double, next: GlucoseEvent?) {
        let start = Calendar.current.startOfDay(for: Date())
        let done = entries.filter { $0.isExercise && !$0.isPlanned && $0.timestamp >= start }.compactMap(\.minutes).reduce(0, +)
        return (done, entries.first(where: \.isPlanned))
    }

    /// The exercise closest to `date` that ended up to 3 hours before it or starts up to 2 hours after it.
    func exercise(near date: Date) -> GlucoseEvent? {
        func gap(_ e: GlucoseEvent) -> TimeInterval { max(0, e.timestamp.timeIntervalSince(date), date.timeIntervalSince(e.end)) }
        return entries.filter { $0.isExercise && gap($0) <= ($0.end < date ? 3 : 2) * 3600 }.min { gap($0) < gap($1) }
    }

    /// Set while low alerts come earlier after exercise.
    var postExercise: PostExercise? { state?.postExercise.flatMap { $0.until > Date() ? $0 : nil } }

    struct NewEvent: Encodable {
        var kind: String
        var timestamp: Date
        var carbs: Double?
        var units: Double?
        var insulinType: String?
        var activity: String?
        var minutes: Double?
        var intensity: String?
        var note: String?
        var photo: String?
        var mediaType: String?
        var estimate: MealEstimate?
    }

    func addEvent(_ event: NewEvent) async throws {
        let _: GlucoseEvent = try await send("POST", "/events", body: event)
        await refresh()
    }

    /// Fields to change on an existing entry; nil fields are left out, so they stay as they are
    /// (set `clearCarbs` or `removePhoto` to clear a value).
    struct EventChange: Encodable {
        var timestamp: Date?
        var carbs: Double?
        var clearCarbs = false
        var units: Double?
        var insulinType: String?
        var activity: String?
        var minutes: Double?
        var intensity: String?
        var note: String?
        var photo: String?
        var mediaType: String?
        var removePhoto: Bool?
        var estimate: MealEstimate?

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(timestamp, forKey: .timestamp)
            if clearCarbs { try c.encodeNil(forKey: .carbs) } else { try c.encodeIfPresent(carbs, forKey: .carbs) }
            try c.encodeIfPresent(units, forKey: .units)
            try c.encodeIfPresent(insulinType, forKey: .insulinType)
            try c.encodeIfPresent(activity, forKey: .activity)
            try c.encodeIfPresent(minutes, forKey: .minutes)
            try c.encodeIfPresent(intensity, forKey: .intensity)
            try c.encodeIfPresent(note, forKey: .note)
            try c.encodeIfPresent(photo, forKey: .photo)
            try c.encodeIfPresent(mediaType, forKey: .mediaType)
            try c.encodeIfPresent(removePhoto, forKey: .removePhoto)
            try c.encodeIfPresent(estimate, forKey: .estimate)
        }

        enum CodingKeys: String, CodingKey {
            case timestamp, carbs, units, insulinType, activity, minutes, intensity, note, photo, mediaType, removePhoto, estimate
        }
    }

    func updateEvent(_ id: Int, _ change: EventChange) async throws {
        let _: GlucoseEvent = try await send("PATCH", "/events/\(id)", body: change)
        await refresh()
    }

    func deleteEvent(_ id: Int) async {
        var req = URLRequest(url: URL(string: "/events/\(id)", relativeTo: Self.server)!)
        req.httpMethod = "DELETE"
        _ = try? await URLSession.shared.data(for: req)
        await refresh()
    }

    func entry(_ id: Int) -> GlucoseEvent? { entries.first { $0.id == id } }

    /// Meals from the last 30 days to log again, newest first, one per description.
    var previousMeals: [GlucoseEvent] {
        var seen = Set<String>()
        return entries.reversed().filter { e in
            guard e.isMeal, let note = e.note?.trimmingCharacters(in: .whitespaces), !note.isEmpty else { return false }
            return seen.insert(note.lowercased()).inserted
        }
    }

    /// A photo saved with an entry (its server path).
    func photo(_ path: String) async -> NSImage? {
        guard let url = URL(string: path, relativeTo: Self.server),
              let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return NSImage(data: data)
    }
    func meal(_ id: Int) -> Meal? { meals.first { $0.id == id } }
    func exerciseImpact(_ id: Int) -> ExerciseImpact? { sessions.first { $0.id == id }?.impact }

    func doseSuggestion(carbs: Double) async throws -> DoseSuggestion {
        try await fetch("/dose?carbs=\(carbs)&target=\(defaults.integer(forKey: "doseTarget"))&low=\(targetLow)")
    }

    struct DoseHistoryRequest: Encodable {
        let carbs: Double; let note: String?; let description: String?; let target: Int; let low: Int; let high: Int
    }

    /// The dose suggestion adjusted by Claude for how the same food went before; slow, so asked after doseSuggestion.
    func doseFromHistory(carbs: Double, note: String?, description: String?) async throws -> DoseSuggestion {
        try await send("POST", "/dose/history", body: DoseHistoryRequest(
            carbs: carbs, note: note, description: description,
            target: defaults.integer(forKey: "doseTarget"), low: targetLow, high: targetHigh))
    }

    func readings(from start: Date, to end: Date) async -> [Point] {
        (try? await get("/readings?start=\(Int(start.timeIntervalSince1970))&end=\(Int(end.timeIntervalSince1970))")) ?? []
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

    /// GET that turns the server's {"error": ...} replies into errors.
    private func fetch<T: Decodable>(_ path: String) async throws -> T {
        let (data, response) = try await URLSession.shared.data(from: URL(string: path, relativeTo: Self.server)!)
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
