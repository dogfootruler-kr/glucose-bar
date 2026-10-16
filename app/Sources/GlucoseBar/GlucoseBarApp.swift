import Charts
import SwiftUI

struct Reading: Decodable {
    let mgdl: Int
    let mmol: Double
    let arrow: String
    let isHigh: Bool
    let isLow: Bool
    let timestamp: Date
    let targetLow: Int?
    let targetHigh: Int?
}

struct Point: Decodable, Identifiable {
    let mgdl: Int
    let timestamp: Date
    var id: Date { timestamp }
}

struct ServerState: Decodable {
    let reading: Reading?
    let history: [Point]
    let error: String?
}

@MainActor
final class GlucoseStore: ObservableObject {
    @Published var state: ServerState?
    @Published var fetchError: String?
    @AppStorage("useMmol") var useMmol = false

    private let url = URL(string: "http://127.0.0.1:8765/glucose")!
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init() {
        Task {
            while true {
                await refresh()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    func refresh() async {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            state = try decoder.decode(ServerState.self, from: data)
            fetchError = nil
        } catch {
            fetchError = "Server unreachable"
        }
    }

    var reading: Reading? { state?.reading }

    var isStale: Bool {
        guard let r = reading else { return true }
        return Date().timeIntervalSince(r.timestamp) > 15 * 60
    }

    func format(_ mgdl: Int) -> String {
        useMmol ? String(format: "%.1f", Double(mgdl) / 18.0182) : "\(mgdl)"
    }

    var title: String {
        guard let r = reading else { return "– –" }
        return "\(format(r.mgdl)) \(r.arrow)" + (isStale ? " ⚠︎" : "")
    }

    // Menu bar labels are drawn as templates (monochrome), so render a non-template image to keep the color.
    var labelImage: NSImage {
        let renderer = ImageRenderer(content: Text(title)
            .font(.system(size: 13, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(color == .secondary ? Color.primary : color))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage()
        image.isTemplate = color == .secondary
        return image
    }

    var color: Color {
        guard let r = reading, !isStale else { return .secondary }
        let low = r.targetLow ?? 70, high = r.targetHigh ?? 180
        if r.mgdl < low { return .red }
        if r.mgdl > high { return .orange }
        return .green
    }
}

@main
struct GlucoseBarApp: App {
    @StateObject private var store = GlucoseStore()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(store: store)
        } label: {
            Image(nsImage: store.labelImage)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuContent: View {
    @ObservedObject var store: GlucoseStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let r = store.reading {
                HStack(alignment: .firstTextBaseline) {
                    Text(store.format(r.mgdl)).font(.system(size: 34, weight: .semibold)).monospacedDigit()
                    Text(store.useMmol ? "mmol/L" : "mg/dL").foregroundStyle(.secondary)
                    Text(r.arrow).font(.title)
                    Spacer()
                }
                .foregroundStyle(store.color)
                Text("Measured \(r.timestamp.formatted(.relative(presentation: .named)))")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("No reading yet").font(.headline)
            }

            if let history = store.state?.history, !history.isEmpty {
                Chart {
                    if let r = store.reading {
                        RectangleMark(yStart: .value("Low", r.targetLow ?? 70),
                                      yEnd: .value("High", r.targetHigh ?? 180))
                            .foregroundStyle(.green.opacity(0.12))
                    }
                    ForEach(history) { p in
                        LineMark(x: .value("Time", p.timestamp), y: .value("mg/dL", p.mgdl))
                            .interpolationMethod(.monotone)
                    }
                }
                .chartYScale(domain: 40...max(250, (history.map(\.mgdl).max() ?? 0) + 20))
                .frame(height: 140)
            }

            if let err = store.fetchError ?? store.state?.error {
                Text(err).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            Toggle("Show mmol/L", isOn: $store.useMmol)
            HStack {
                Button("Refresh") { Task { await store.refresh() } }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding()
        .frame(width: 300)
    }
}
