import Charts
import SwiftUI

/// Every meal and insulin entry from the last 30 days, by day, with a detail inspector.
struct JournalView: View {
    @ObservedObject var store: GlucoseStore
    @Environment(\.windowOpener) private var open
    @State private var filter = Filter.all
    @State private var order = Order.date
    @State private var selection: Int?
    @State private var editing: GlucoseEvent?
    @State private var deleting: GlucoseEvent?
    @State private var showInspector = true

    enum Filter: String, CaseIterable { case all = "All", meals = "Meals", insulin = "Insulin" }
    enum Order { case date, best, worst }

    private var visible: [GlucoseEvent] {
        let list = store.entries.filter {
            switch filter {
            case .all: true
            case .meals: $0.isMeal
            case .insulin: !$0.isMeal
            }
        }
        switch order {
        case .date:
            return list.reversed()
        case .best, .worst:
            let scored = list.filter { store.meal($0.id)?.score != nil }
            return scored.sorted {
                let a = store.meal($0.id)!.score!, b = store.meal($1.id)!.score!
                return order == .best ? a > b : a < b
            }
        }
    }

    private var days: [(day: Date, entries: [GlucoseEvent])] {
        Dictionary(grouping: visible) { Calendar.current.startOfDay(for: $0.timestamp) }
            .map { ($0.key, $0.value) }
            .sorted { $0.day > $1.day }
    }

    var body: some View {
        Group {
            if store.entries.isEmpty {
                ContentUnavailableView {
                    Label("No Entries Yet", systemImage: "fork.knife")
                } description: {
                    Text("Meals and insulin you log appear here, with how your glucose responded.")
                } actions: {
                    Button("New Entry…") { open("log") }
                }
            } else {
                list
            }
        }
        .frame(minWidth: 520, minHeight: 460)
        .navigationTitle("Journal")
        .navigationSubtitle("Last 30 days")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .onChange(of: filter) { if filter != .meals { order = .date } }
            }
            ToolbarItem {
                Menu {
                    Picker("Sort", selection: $order) {
                        Text("By Date").tag(Order.date)
                        Text("Easiest on Glucose First").tag(Order.best)
                        Text("Hardest on Glucose First").tag(Order.worst)
                    }
                    .pickerStyle(.inline)
                    .onChange(of: order) { if order != .date { filter = .meals } }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .help("Sort meals by score")
            }
            ToolbarItem {
                Button { open("log") } label: { Label("New Entry", systemImage: "plus") }
                    .help("Log a meal or insulin")
            }
            ToolbarItem {
                Button { showInspector.toggle() } label: { Label("Details", systemImage: "sidebar.right") }
                    .help(showInspector ? "Hide details" : "Show details")
            }
        }
        .inspector(isPresented: $showInspector) {
            Group {
                if let id = selection, let entry = store.entry(id) {
                    EntryDetail(store: store, entry: entry, meal: store.meal(id),
                                onEdit: { editing = entry }, onDelete: { deleting = entry })
                } else {
                    ContentUnavailableView("No Selection", systemImage: "sidebar.right",
                                           description: Text("Select an entry to see how your glucose responded."))
                }
            }
            .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
        }
        .sheet(item: $editing) { EntryEditor(store: store, existing: $0) }
        .confirmationDialog("Delete this entry?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { entry in
            Button("Delete", role: .destructive) {
                Task {
                    if selection == entry.id { selection = nil }
                    await store.deleteEvent(entry.id)
                }
            }
        } message: { entry in
            Text("“\(entry.title)” will be removed. This can't be undone.")
        }
        .activatesWindow("journal")
    }

    private var list: some View {
        List(selection: $selection) {
            if order == .date {
                ForEach(days, id: \.day) { day in
                    Section {
                        ForEach(day.entries) { row($0) }
                    } header: {
                        DayHeader(day: day.day, entries: day.entries)
                    }
                }
            } else {
                ForEach(visible) { row($0) }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: false))
        .contextMenu(forSelectionType: Int.self) { ids in
            if let id = ids.first, let entry = store.entry(id) {
                Button("Edit…") { editing = entry }
                Divider()
                Button("Delete…", role: .destructive) { deleting = entry }
            }
        } primaryAction: { ids in
            if let id = ids.first { editing = store.entry(id) }
        }
        .onDeleteCommand { if let id = selection { deleting = store.entry(id) } }
    }

    private func row(_ entry: GlucoseEvent) -> some View {
        EntryRow(store: store, entry: entry, meal: store.meal(entry.id), showsDay: order != .date)
            .tag(entry.id)
    }
}

private struct DayHeader: View {
    let day: Date
    let entries: [GlucoseEvent]

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(totals).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    private var title: String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    private var totals: String {
        let carbs = entries.compactMap(\.carbs).reduce(0, +)
        let rapid = entries.filter(\.isRapid).compactMap(\.units).reduce(0, +)
        let long = entries.filter { !$0.isMeal && !$0.isRapid }.compactMap(\.units).reduce(0, +)
        var parts: [String] = []
        if carbs > 0 { parts.append("\(Int(carbs)) g carbs") }
        if rapid > 0 { parts.append("\(formatUnits(rapid)) u rapid") }
        if long > 0 { parts.append("\(formatUnits(long)) u long") }
        return parts.joined(separator: " · ")
    }
}

/// One meal or insulin entry, used in the journal and the menu bar popup.
struct EntryRow: View {
    @ObservedObject var store: GlucoseStore
    let entry: GlucoseEvent
    let meal: Meal?
    var compact = false
    var showsDay = false

    var body: some View {
        HStack(spacing: 10) {
            EntryIcon(entry: entry, size: compact ? 28 : 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title).lineLimit(1)
                Text(details).font(compact ? .caption : .subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let meal, let score = meal.score {
                VStack(alignment: .trailing, spacing: 2) {
                    ScoreBadge(score: score, complete: meal.impact?.complete ?? true, size: compact ? 26 : 32)
                    if !compact, let label = meal.dose?.verdictLabel, meal.dose?.verdict != "none" {
                        Text(label).font(.caption2).foregroundStyle(doseColor(meal.dose?.verdict))
                    }
                }
            }
        }
        .padding(.vertical, compact ? 0 : 3)
    }

    private var details: String {
        let time = entry.timestamp.formatted(showsDay ? .dateTime.weekday().day().month().hour().minute() : .dateTime.hour().minute())
        var parts = [time]
        if entry.isMeal {
            if let c = entry.carbs { parts.append("\(Int(c)) g carbs") }
            if let d = meal?.dose, d.units > 0 { parts.append("\(formatUnits(d.units)) u") }
        } else if let note = entry.note {
            parts.append(note)
        }
        return parts.joined(separator: " · ")
    }
}

func doseColor(_ verdict: String?) -> Color {
    switch verdict {
    case "ok": .green
    case "tooLittle", "tooMuch": .orange
    default: .secondary
    }
}

struct EntryIcon: View {
    let entry: GlucoseEvent
    let size: CGFloat

    var body: some View {
        if entry.isMeal, let photo = entry.photo, let url = URL(string: photo, relativeTo: GlucoseStore.server) {
            AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { Color.secondary.opacity(0.15) }
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        } else {
            let tint: Color = entry.isMeal ? .orange : entry.isRapid ? .purple : .indigo
            Image(systemName: entry.isMeal ? "fork.knife" : "syringe.fill")
                .font(.system(size: size * 0.42, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        }
    }
}

/// A meal's food score as a ring.
struct ScoreBadge: View {
    let score: Int
    var complete = true
    var size: CGFloat = 32

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.2), lineWidth: size * 0.11)
            Circle()
                .trim(from: 0, to: CGFloat(score) / 100)
                .stroke(color, style: StrokeStyle(lineWidth: size * 0.11, lineCap: .round, dash: complete ? [] : [2, 2]))
                .rotationEffect(.degrees(-90))
            Text("\(score)").font(.system(size: size * 0.36, weight: .semibold, design: .rounded)).monospacedDigit()
        }
        .frame(width: size, height: size)
        .help(complete ? "Food score: how gently glucose rose in the first 90 minutes" : "Food score so far")
    }

    var color: Color { score >= 80 ? .green : score >= 50 ? .orange : .red }
}

/// Inspector content: a meal's glucose response and dose, or an insulin entry.
struct EntryDetail: View {
    @ObservedObject var store: GlucoseStore
    let entry: GlucoseEvent
    let meal: Meal?
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var readings: [Point] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if entry.isMeal {
                    responseChart
                    if let meal { mealFacts(meal) }
                    if let estimate = entry.estimate { estimateBox(estimate) }
                } else if let note = entry.note {
                    Text(note)
                }
                HStack {
                    Button("Edit…", action: onEdit)
                    Button("Delete…", role: .destructive, action: onDelete)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: entry) {
            readings = await store.readings(from: entry.timestamp.addingTimeInterval(-30 * 60),
                                            to: entry.timestamp.addingTimeInterval(4 * 3600))
        }
    }

    @ViewBuilder private var header: some View {
        if entry.isMeal, let photo = entry.photo, let url = URL(string: photo, relativeTo: GlucoseStore.server) {
            AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { Color.secondary.opacity(0.1) }
                .frame(height: 170)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.title).font(.title2.weight(.semibold))
            Text(entry.timestamp.formatted(.dateTime.weekday(.wide).day().month().hour().minute()))
                .foregroundStyle(.secondary)
        }
    }

    private var responseChart: some View {
        let end = entry.timestamp.addingTimeInterval(4 * 3600)
        let nearby = store.entries.filter { $0.timestamp >= entry.timestamp.addingTimeInterval(-3600) && $0.timestamp <= end }
        let low = store.targetLow, high = store.targetHigh
        return Chart {
            RectangleMark(yStart: .value("Low", low), yEnd: .value("High", high)).foregroundStyle(.green.opacity(0.1))
            ForEach(readings) { p in
                LineMark(x: .value("Time", p.timestamp), y: .value("Glucose", p.mgdl)).interpolationMethod(.monotone)
            }
            ForEach(nearby) { e in
                RuleMark(x: .value("Time", e.timestamp))
                    .foregroundStyle((e.isMeal ? Color.orange : .purple).opacity(e.id == entry.id ? 0.8 : 0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: e.isMeal ? [] : [3, 2]))
                    .annotation(position: .top, spacing: 2) {
                        Text(e.isMeal ? "\(Int(e.carbs ?? 0))g" : "\(formatUnits(e.units ?? 0))u")
                            .font(.caption2)
                            .foregroundStyle(e.isMeal ? .orange : .purple)
                    }
            }
        }
        .chartXScale(domain: entry.timestamp.addingTimeInterval(-30 * 60)...end)
        .chartYScale(domain: 40...max(250, (readings.map(\.mgdl).max() ?? 0) + 20))
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { v in
                AxisGridLine()
                AxisValueLabel { if let mg = v.as(Int.self) { Text(store.format(mg)) } }
            }
        }
        .frame(height: 150)
        .overlay {
            if readings.isEmpty { Text("No readings").font(.caption).foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder private func mealFacts(_ meal: Meal) -> some View {
        if let i = meal.impact {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        ScoreBadge(score: meal.score ?? i.score, complete: i.complete, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(i.complete ? "Food score" : "Food score so far").font(.headline)
                            Text("Rose \(store.format(i.earlyRise ?? i.rise)) in the first 90 minutes")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                    fact("Peak", "\(store.format(i.peak)), \(i.minutesToPeak) min after eating")
                    fact("Above range", i.minutesAboveHigh > 0 ? "\(i.minutesAboveHigh) min" : "None")
                    if let b = i.minutesToBaseline { fact("Back to start", "after \(b) min") }
                    fact("Overall response", "\(i.score) / 100")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        if let d = meal.dose {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Label(d.verdictLabel ?? "Dose: too early to tell", systemImage: doseSymbol(d.verdict))
                        .font(.headline)
                        .foregroundStyle(doseColor(d.verdict))
                    if let reason = d.reason { Text(reason).foregroundStyle(.secondary) }
                    Divider()
                    if d.units > 0 {
                        fact("Rapid insulin", "\(formatUnits(d.units)) u" + timing(d.minutesFromMeal))
                    }
                    if d.laterUnits > 0 { fact("Later doses", "\(formatUnits(d.laterUnits)) u") }
                    if d.sharedWith > 0 { fact("Carbs covered", "\(Int(d.carbs)) g, with \(d.sharedWith) other item\(d.sharedWith == 1 ? "" : "s")") }
                    if let s = d.suggested { fact("Your usual ratio", "\(formatUnits(s)) u for \(Int(d.carbs)) g") }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("The food score looks at the first 90 minutes, so a dose that was off doesn't count against the food.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func estimateBox(_ estimate: MealEstimate) -> some View {
        GroupBox("Claude's estimate") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(estimate.items, id: \.name) { fact($0.name, "\(Int($0.carbs)) g") }
                if let note = estimate.note { Text(note).font(.caption).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }
        .font(.callout)
    }

    private func timing(_ minutes: Int?) -> String {
        guard let m = minutes else { return "" }
        if abs(m) < 3 { return ", when eating" }
        return m < 0 ? ", \(-m) min before eating" : ", \(m) min after eating"
    }

    private func doseSymbol(_ verdict: String?) -> String {
        switch verdict {
        case "ok": "checkmark.circle.fill"
        case "tooLittle": "arrow.up.circle.fill"
        case "tooMuch": "arrow.down.circle.fill"
        default: "clock"
        }
    }
}
