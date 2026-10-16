import Charts
import SwiftUI

struct MenuContent: View {
    @ObservedObject var store: GlucoseStore
    @ObservedObject var alerts: AlertManager
    @AppStorage("chartHours") private var chartHours = 12
    @AppStorage("useMmol") private var useMmol = false
    @AppStorage("targetLow") private var targetLow = 70
    @AppStorage("targetHigh") private var targetHigh = 180
    @State private var hovered: Point?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            current
            chart
            statsGrid
            sensorRow
            if let err = store.fetchError ?? store.state?.error {
                Text(err).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            actions
        }
        .padding()
        .frame(width: 330)
    }

    @ViewBuilder private var current: some View {
        if let r = store.reading {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(store.format(r.mgdl)).font(.system(size: 34, weight: .semibold)).monospacedDigit()
                    Text(r.arrow).font(.title)
                    if let d = r.delta {
                        Text(formatDelta(d, mmol: useMmol)).font(.title3).monospacedDigit()
                    }
                    Text(useMmol ? "mmol/L" : "mg/dL").foregroundStyle(.secondary)
                    Spacer()
                }
                .foregroundStyle(store.color)
                Text("Measured \(r.timestamp.formatted(.relative(presentation: .named)))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Text("No reading yet").font(.headline)
        }
    }

    private var chart: some View {
        VStack(spacing: 6) {
            Picker("", selection: $chartHours) {
                ForEach([3, 6, 12, 24], id: \.self) { Text("\($0)h").tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: chartHours) { Task { await store.refresh() } }

            let points = store.history(lastHours: Double(chartHours))
            let maxValue = max(250, (points.map(\.mgdl).max() ?? 0) + 20)
            Chart {
                RectangleMark(yStart: .value("Low", targetLow), yEnd: .value("High", targetHigh))
                    .foregroundStyle(.green.opacity(0.12))
                ForEach(points) { p in
                    LineMark(x: .value("Time", p.timestamp), y: .value("Glucose", p.mgdl))
                        .interpolationMethod(.monotone)
                }
                if let h = hovered {
                    RuleMark(x: .value("Time", h.timestamp))
                        .foregroundStyle(.secondary.opacity(0.5))
                        .annotation(position: .top, spacing: 2, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                            VStack(spacing: 0) {
                                Text("\(store.format(h.mgdl)) \(useMmol ? "mmol/L" : "mg/dL")").font(.caption.bold()).monospacedDigit()
                                Text(h.timestamp.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(.background, in: RoundedRectangle(cornerRadius: 5))
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(.separator))
                        }
                    PointMark(x: .value("Time", h.timestamp), y: .value("Glucose", h.mgdl))
                        .symbolSize(40)
                        .foregroundStyle(color(for: h.mgdl))
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            guard case .active(let location) = phase, let frame = proxy.plotFrame,
                                  let date: Date = proxy.value(atX: location.x - geo[frame].origin.x) else {
                                hovered = nil
                                return
                            }
                            hovered = points.min { abs($0.timestamp.timeIntervalSince(date)) < abs($1.timestamp.timeIntervalSince(date)) }
                        }
                }
            }
            .chartXScale(domain: Date().addingTimeInterval(-Double(chartHours) * 3600)...Date())
            .chartYScale(domain: 40...maxValue)
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { v in
                    AxisGridLine()
                    AxisValueLabel { if let mg = v.as(Int.self) { Text(store.format(mg)) } }
                }
            }
            .frame(height: 150)
            if chartHours > 12, let first = points.first, first.timestamp > Date().addingTimeInterval(-Double(chartHours) * 3600 + 1800) {
                Text("History builds up from the first time the server ran.").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func color(for mgdl: Int) -> Color {
        mgdl < targetLow ? .red : mgdl > targetHigh ? .orange : .green
    }

    private var statsGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
            GridRow {
                Text("")
                Text("In range").foregroundStyle(.secondary)
                Text("Average").foregroundStyle(.secondary)
                Text("A1c est.").foregroundStyle(.secondary)
            }
            .font(.caption)
            statsRow("Today", store.stats?.today)
            statsRow("7 days", store.stats?.week)
        }
    }

    private func statsRow(_ label: String, _ s: Stats?) -> some View {
        GridRow {
            Text(label).font(.caption).foregroundStyle(.secondary)
            if let s {
                Text("\(s.inRange)%").help("\(s.below)% below · \(s.above)% above")
                Text(store.format(s.average))
                Text(String(format: "%.1f%%", s.gmi))
            } else {
                Text("–"); Text("–"); Text("–")
            }
        }
        .monospacedDigit()
    }

    @ViewBuilder private var sensorRow: some View {
        if let ends = store.sensorEnds {
            let left = ends.timeIntervalSinceNow
            HStack {
                Image(systemName: "sensor.tag.radiowaves.forward")
                if left > 0 {
                    Text("Sensor ends in \(Duration.seconds(left).formatted(.units(allowed: [.days, .hours], width: .abbreviated)))")
                } else {
                    Text("Sensor expired")
                }
                Spacer()
                Text(ends.formatted(.dateTime.weekday(.abbreviated).hour().minute())).foregroundStyle(.secondary)
            }
            .font(.caption)
            .foregroundStyle(left < 86400 ? .orange : .primary)
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            if alerts.isSnoozed, let until = alerts.snoozedUntil {
                HStack {
                    Image(systemName: "bell.slash")
                    Text("Alerts off until \(until.formatted(date: .omitted, time: .shortened))")
                    Spacer()
                    Button("Resume") { alerts.cancelSnooze() }
                }
                .font(.caption)
            }
            HStack {
                if !alerts.isSnoozed {
                    Button("Snooze alerts 30 min") { alerts.snooze() }
                }
                Spacer()
                Menu("More") {
                    Button("Open web page") { store.openWebPage() }
                    Button("Export CSV…") { store.exportCSV() }
                    Button("Refresh now") { Task { await store.refresh() } }
                }
                .fixedSize()
            }
            HStack {
                SettingsLink { Text("Settings…") }
                    .simultaneousGesture(TapGesture().onEnded { NSApp.activate(ignoringOtherApps: true) })
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
    }
}
