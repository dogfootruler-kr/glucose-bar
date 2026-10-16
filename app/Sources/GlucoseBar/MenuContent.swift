import Charts
import SwiftUI

struct MenuContent: View {
    @ObservedObject var store: GlucoseStore
    @ObservedObject var alerts: AlertManager
    @Environment(\.openWindow) private var openWindow
    @AppStorage("chartHours") private var chartHours = 12
    @AppStorage("useMmol") private var useMmol = false
    @AppStorage("alertLow") private var alertLow = 70

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            current
            GlucoseChart(store: store, hours: $chartHours)
            statsGrid
            insulinRow
            sensorRow
            recentMeals
            summaryRow
            if let err = store.fetchError ?? store.state?.error {
                Text(err).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            actions
        }
        .padding()
        .frame(width: 340)
    }

    private func open(_ id: String) {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: id)
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
                    Button { open("log") } label: { Image(systemName: "plus.circle.fill").font(.title2) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                        .help("Log a meal or insulin")
                }
                .foregroundStyle(store.color)
                Text("Measured \(r.timestamp.formatted(.relative(presentation: .named)))")
                    .font(.caption).foregroundStyle(.secondary)
                if let fc = store.state?.forecast {
                    forecastLine(fc)
                }
            }
        } else {
            Text("No reading yet").font(.headline)
        }
    }

    @ViewBuilder private func forecastLine(_ fc: Forecast) -> some View {
        if let hit = fc.crossing(below: alertLow) {
            Label("Heading low: \(store.format(hit.mgdl)) around \(hit.date.formatted(date: .omitted, time: .shortened))",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption.bold()).foregroundStyle(.red)
        } else if let v = fc.in30, abs(fc.slope) >= 1 {
            Label("About \(store.format(v)) in 30 min if the trend continues", systemImage: "chart.line.uptrend.xyaxis")
                .font(.caption).foregroundStyle(.secondary)
        }
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

    @ViewBuilder private var insulinRow: some View {
        let today = store.insulinToday()
        if today.rapid + today.long > 0 {
            HStack {
                Image(systemName: "syringe")
                Text("Insulin today: \(formatUnits(today.rapid)) u rapid · \(formatUnits(today.long)) u long")
                Spacer()
            }
            .font(.caption)
        }
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

    @ViewBuilder private var recentMeals: some View {
        let recent = store.meals.suffix(3).reversed()
        if !recent.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Recent meals").font(.caption.bold()).foregroundStyle(.secondary)
                    Spacer()
                    Button("All meals") { open("meals") }.buttonStyle(.link).font(.caption)
                }
                ForEach(Array(recent)) { MealRow(meal: $0, store: store, compact: true) }
            }
        }
    }

    @ViewBuilder private var summaryRow: some View {
        if store.summary != nil || store.aiAvailable {
            Button { open("summary") } label: {
                HStack {
                    Image(systemName: "text.document")
                    Text(store.summary.map { "Weekly summary · \($0.created.formatted(.dateTime.weekday(.wide)))" } ?? "Weekly summary")
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                }
                .font(.caption)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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
                    Button("Log meal or insulin…") { open("log") }
                    Button("All meals…") { open("meals") }
                    Button("Weekly summary…") { open("summary") }
                    Divider()
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

/// History, 30-minute forecast, meal/insulin markers and a hover tooltip.
struct GlucoseChart: View {
    @ObservedObject var store: GlucoseStore
    @Binding var hours: Int
    @AppStorage("useMmol") private var useMmol = false
    @AppStorage("targetLow") private var targetLow = 70
    @AppStorage("targetHigh") private var targetHigh = 180
    @State private var hovered: Date?

    var body: some View {
        VStack(spacing: 6) {
            Picker("", selection: $hours) {
                ForEach([3, 6, 12, 24], id: \.self) { Text("\($0)h").tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: hours) { Task { await store.refresh() } }

            let start = Date().addingTimeInterval(-Double(hours) * 3600)
            let points = store.history(lastHours: Double(hours))
            let forecast = store.state?.forecast
            let events = store.events.filter { $0.timestamp >= start }
            let end = forecast?.points.last?.timestamp ?? Date()
            let maxValue = max(250, ((points + (forecast?.points ?? [])).map(\.mgdl).max() ?? 0) + 30)
            let hoveredPoint = hovered.flatMap { h in points.min { abs($0.timestamp.timeIntervalSince(h)) < abs($1.timestamp.timeIntervalSince(h)) } }
            let hoveredEvents = hovered.map { h in events.filter { abs($0.timestamp.timeIntervalSince(h)) < Double(hours) * 60 } } ?? []

            Chart {
                RectangleMark(yStart: .value("Low", targetLow), yEnd: .value("High", targetHigh))
                    .foregroundStyle(.green.opacity(0.12))
                ForEach(points) { p in
                    LineMark(x: .value("Time", p.timestamp), y: .value("Glucose", p.mgdl), series: .value("Series", "history"))
                        .interpolationMethod(.monotone)
                }
                if let forecast, let last = points.last {
                    ForEach([Point(mgdl: last.mgdl, timestamp: last.timestamp)] + forecast.points) { p in
                        LineMark(x: .value("Time", p.timestamp), y: .value("Glucose", p.mgdl), series: .value("Series", "forecast"))
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(events) { e in
                    PointMark(x: .value("Time", e.timestamp), y: .value("Glucose", maxValue - 12))
                        .symbol {
                            Image(systemName: e.isMeal ? "fork.knife.circle.fill" : "syringe.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(e.isMeal ? .orange : .purple)
                        }
                }
                if let h = hoveredPoint {
                    RuleMark(x: .value("Time", h.timestamp))
                        .foregroundStyle(.secondary.opacity(0.5))
                        .annotation(position: .top, spacing: 2, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(store.format(h.mgdl)) \(useMmol ? "mmol/L" : "mg/dL")").font(.caption.bold()).monospacedDigit()
                                Text(h.timestamp.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                                ForEach(hoveredEvents) { e in
                                    Label(e.label, systemImage: e.isMeal ? "fork.knife" : "syringe").font(.caption2)
                                }
                            }
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(.background, in: RoundedRectangle(cornerRadius: 5))
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(.separator))
                        }
                    PointMark(x: .value("Time", h.timestamp), y: .value("Glucose", h.mgdl))
                        .symbolSize(40)
                        .foregroundStyle(h.mgdl < targetLow ? .red : h.mgdl > targetHigh ? .orange : .green)
                }
            }
            .chartXScale(domain: start...end)
            .chartYScale(domain: 40...maxValue)
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { v in
                    AxisGridLine()
                    AxisValueLabel { if let mg = v.as(Int.self) { Text(store.format(mg)) } }
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
                            hovered = date
                        }
                }
            }
            .frame(height: 160)
            if hours > 12, let first = points.first, first.timestamp > start.addingTimeInterval(1800) {
                Text("History builds up from the first time the server ran.").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
