import Charts
import SwiftUI

/// The menu bar popup, laid out like a Control Center module: reading, chart, stats, recent
/// meals, then menu-style rows.
struct MenuContent: View {
    @ObservedObject var store: GlucoseStore
    @ObservedObject var alerts: AlertManager
    @Environment(\.windowOpener) private var open
    @AppStorage("chartHours") private var chartHours = 12
    @AppStorage("useMmol") private var useMmol = false
    @AppStorage("alertLow") private var alertLow = 70

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 12) {
                current
                GlucoseChart(store: store, hours: $chartHours)
                statTiles
                infoRows
                recentMeals
                if let err = store.fetchError ?? store.state?.error {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding([.horizontal, .top], 14)
            Divider().padding(.horizontal, 14)
            menu.padding(.horizontal, 5).padding(.bottom, 5)
        }
        .frame(width: 340)
    }

    // MARK: reading

    @ViewBuilder private var current: some View {
        HStack(alignment: .top) {
            if let r = store.reading {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(store.format(r.mgdl)).font(.system(size: 38, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text(r.arrow).font(.system(size: 26, weight: .medium))
                        VStack(alignment: .leading, spacing: 0) {
                            if let d = r.delta { Text(formatDelta(d, mmol: useMmol)).monospacedDigit() }
                            Text(useMmol ? "mmol/L" : "mg/dL").foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                    .foregroundStyle(store.color)
                    Text("Measured \(r.timestamp.formatted(.relative(presentation: .named)))")
                        .font(.caption).foregroundStyle(.secondary)
                    if let fc = store.state?.forecast { forecastLine(fc) }
                }
            } else {
                Text("No reading yet").font(.headline)
            }
            Spacer()
            Button { open("log") } label: {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .background(.tint.opacity(0.15), in: Circle())
                    .foregroundStyle(.tint)
            }
            .buttonStyle(.plain)
            .help("Log a meal or insulin")
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

    // MARK: stats

    private var statTiles: some View {
        let today = store.stats?.today, week = store.stats?.week
        return HStack(spacing: 8) {
            StatTile(title: "In range", today: today.map { "\($0.inRange)%" }, week: week.map { "\($0.inRange)%" })
            StatTile(title: "Average", today: today.map { store.format($0.average) }, week: week.map { store.format($0.average) })
            StatTile(title: "A1c est.", today: today.map { String(format: "%.1f%%", $0.gmi) }, week: week.map { String(format: "%.1f%%", $0.gmi) })
        }
    }

    @ViewBuilder private var infoRows: some View {
        let insulin = store.insulinToday()
        if insulin.rapid + insulin.long > 0 || store.sensorEnds != nil {
            VStack(spacing: 6) {
                if insulin.rapid + insulin.long > 0 {
                    InfoRow(symbol: "syringe", text: "Insulin today",
                            value: "\(formatUnits(insulin.rapid)) u rapid · \(formatUnits(insulin.long)) u long")
                }
                if let ends = store.sensorEnds {
                    let left = ends.timeIntervalSinceNow
                    InfoRow(symbol: "sensor.tag.radiowaves.forward",
                            text: left > 0 ? "Sensor ends in \(Duration.seconds(left).formatted(.units(allowed: [.days, .hours], width: .abbreviated)))" : "Sensor expired",
                            value: ends.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                        .foregroundStyle(left < 86400 ? .orange : .primary)
                }
            }
        }
    }

    @ViewBuilder private var recentMeals: some View {
        let recent = store.meals.suffix(3).reversed()
        if !recent.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Recent Meals").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(Array(recent)) { meal in
                    if let entry = store.entry(meal.id) {
                        Button { open.edit(meal.id) } label: {
                            EntryRow(store: store, entry: entry, meal: meal, compact: true).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Edit this meal")
                    }
                }
            }
        }
    }

    // MARK: menu

    private var menu: some View {
        VStack(spacing: 0) {
            MenuRow("Log Meal or Insulin…", symbol: "plus.circle") { open("log") }
            MenuRow("Journal", symbol: "list.bullet.rectangle") { open("journal") }
            if store.summary != nil || store.aiAvailable {
                MenuRow("Weekly Summary", symbol: "text.document",
                        detail: store.summary.map { $0.created.formatted(.dateTime.weekday(.wide)) }) { open("summary") }
            }
            Divider().padding(.horizontal, 9).padding(.vertical, 4)
            if alerts.isSnoozed, let until = alerts.snoozedUntil {
                MenuRow("Resume Alerts", symbol: "bell",
                        detail: "Off until \(until.formatted(date: .omitted, time: .shortened))") { alerts.cancelSnooze() }
            } else {
                MenuRow("Snooze Alerts for 30 Minutes", symbol: "bell.slash") { alerts.snooze() }
            }
            MenuRow("Open Web Page", symbol: "safari") { store.openWebPage() }
            MenuRow("Export CSV…", symbol: "square.and.arrow.up") { store.exportCSV() }
            Divider().padding(.horizontal, 9).padding(.vertical, 4)
            MenuRow("Settings…", symbol: "gearshape") { open("settings") }
            MenuRow("Quit GlucoseBar", symbol: "power") { NSApplication.shared.terminate(nil) }
        }
    }
}

private struct StatTile: View {
    let title: String
    let today: String?
    let week: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(today ?? "–").font(.system(.title3, design: .rounded).weight(.semibold)).monospacedDigit()
            Text("7 days \(week ?? "–")").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .help("\(title): today, and the last 7 days")
    }
}

private struct InfoRow: View {
    let symbol: String
    let text: String
    let value: String

    var body: some View {
        HStack {
            Image(systemName: symbol).frame(width: 16).foregroundStyle(.secondary)
            Text(text)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
        .font(.callout)
    }
}

/// A full-width row that highlights on hover, like a menu item.
private struct MenuRow: View {
    let title: String
    let symbol: String
    var detail: String?
    let action: () -> Void
    @State private var hovering = false

    init(_ title: String, symbol: String, detail: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.detail = detail
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 18)
                Text(title)
                Spacer()
                if let detail { Text(detail).foregroundStyle(hovering ? .white.opacity(0.8) : .secondary) }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .foregroundStyle(hovering ? .white : .primary)
            .background(hovering ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
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
