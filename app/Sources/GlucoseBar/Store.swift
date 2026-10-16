import AppKit
import SwiftUI

@MainActor
final class GlucoseStore: ObservableObject {
    static let server = URL(string: "http://127.0.0.1:8765")!

    @Published var state: ServerState?
    @Published var stats: StatsResponse?
    @Published var fetchError: String?
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
            fetchError = nil
            lastSuccess = Date()
        } catch {
            fetchError = "Server unreachable"
        }
        alerts.evaluate(reading: reading, stale: isStale, staleSince: staleSince)
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

    func openWebPage() {
        NSWorkspace.shared.open(Self.server)
    }
}
