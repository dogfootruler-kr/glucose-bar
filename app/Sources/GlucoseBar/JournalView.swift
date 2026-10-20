import Charts
import SwiftUI

/// Every meal, insulin and exercise entry from the last 30 days, by day, with a detail inspector.
struct JournalView: View {
    @ObservedObject var store: GlucoseStore
    @Environment(\.windowOpener) private var open
    @State private var filter = Filter.all
    @State private var order = Order.date
    @State private var selection: Int?
    @State private var editing: GlucoseEvent?
    @State private var deleting: GlucoseEvent?
    @State private var showInspector = true

    enum Filter: String, CaseIterable { case all = "All", meals = "Meals", insulin = "Insulin", exercise = "Exercise" }
    enum Order { case date, best, worst }

    private var visible: [GlucoseEvent] {
        let list = store.entries.filter {
            switch filter {
            case .all: true
            case .meals: $0.isMeal
            case .insulin: $0.isInsulin
            case .exercise: $0.isExercise
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
                    Text("Meals, insulin and exercise you log appear here, with how your glucose responded.")
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
                    .help("Log a meal, insulin or exercise")
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
        if cal.isDateInTomorrow(day) { return "Tomorrow" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    private var totals: String {
        let carbs = entries.compactMap(\.carbs).reduce(0, +)
        let rapid = entries.filter(\.isRapid).compactMap(\.units).reduce(0, +)
        let long = entries.filter(\.isLong).compactMap(\.units).reduce(0, +)
        let exercise = entries.filter { $0.isExercise && !$0.isPlanned }.compactMap(\.minutes).reduce(0, +)
        let planned = entries.filter(\.isPlanned).compactMap(\.minutes).reduce(0, +)
        var parts: [String] = []
        if carbs > 0 { parts.append("\(Int(carbs)) g carbs") }
        if rapid > 0 { parts.append("\(formatUnits(rapid)) u rapid") }
        if long > 0 { parts.append("\(formatUnits(long)) u long") }
        if exercise > 0 { parts.append("\(formatMinutes(exercise)) exercise") }
        if planned > 0 { parts.append("\(formatMinutes(planned)) planned") }
        return parts.joined(separator: " · ")
    }
}

/// One entry, used in the journal and the menu bar popup.
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
            if entry.isExercise, let low = store.exerciseImpact(entry.id)?.lowAfter {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .help("Went down to \(store.format(low.mgdl)) \(formatMinutes(Double(low.minutesAfter ?? 0))) after")
            }
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
        switch entry.kind {
        case "meal":
            if let c = entry.carbs { parts.append("\(Int(c)) g carbs") }
            if let d = meal?.dose, d.units > 0 { parts.append("\(formatUnits(d.units)) u") }
            if meal?.exercise != nil { parts.append("with exercise") }
        case "exercise":
            if entry.isPlanned { parts.insert("Planned", at: 0) }
            parts += [entry.intensity?.capitalized, entry.note].compactMap { $0 }
        default:
            if let note = entry.note { parts.append(note) }
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
            Image(systemName: entry.symbol)
                .font(.system(size: size * 0.42, weight: .medium))
                .foregroundStyle(entry.tint)
                .frame(width: size, height: size)
                .background(entry.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
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

/// Inspector content: a meal's glucose response and dose, an exercise session's, or an insulin entry.
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
                } else if entry.isExercise {
                    if !entry.isPlanned { responseChart }
                    exerciseFacts
                    if let note = entry.note { Text(note) }
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
            readings = await store.readings(from: window.lowerBound, to: window.upperBound)
        }
    }

    /// The chart's time span: 4 hours after a meal or dose; for exercise, up to 12 hours after it ends,
    /// when delayed lows show up.
    private var window: ClosedRange<Date> {
        let start = entry.timestamp.addingTimeInterval(-30 * 60)
        guard entry.isExercise else { return start...entry.timestamp.addingTimeInterval(4 * 3600) }
        return start...min(entry.end.addingTimeInterval(12 * 3600), max(Date(), entry.end.addingTimeInterval(3600)))
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
        let window = window
        let nearby = store.entries.filter { $0.end >= window.lowerBound && $0.timestamp <= window.upperBound }
        let low = store.targetLow, high = store.targetHigh
        return Chart {
            RectangleMark(yStart: .value("Low", low), yEnd: .value("High", high)).foregroundStyle(.green.opacity(0.1))
            ForEach(nearby.filter(\.isExercise)) { e in
                RectangleMark(xStart: .value("Start", max(e.timestamp, window.lowerBound)), xEnd: .value("End", min(e.end, window.upperBound)))
                    .foregroundStyle(.teal.opacity(e.id == entry.id ? 0.18 : 0.08))
            }
            ForEach(readings) { p in
                LineMark(x: .value("Time", p.timestamp), y: .value("Glucose", p.mgdl)).interpolationMethod(.monotone)
            }
            ForEach(nearby.filter { $0.timestamp >= window.lowerBound }) { e in
                RuleMark(x: .value("Time", e.timestamp))
                    .foregroundStyle(e.tint.opacity(e.id == entry.id ? 0.8 : 0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: e.isInsulin ? [3, 2] : []))
                    .annotation(position: .top, spacing: 2) {
                        Text(e.shortLabel).font(.caption2).foregroundStyle(e.tint)
                    }
            }
            if entry.isExercise, let low = store.exerciseImpact(entry.id)?.lowAfter {
                PointMark(x: .value("Time", low.timestamp), y: .value("Glucose", low.mgdl))
                    .foregroundStyle(.red)
                    .annotation(position: .bottom, spacing: 2) { Text("Low").font(.caption2).foregroundStyle(.red) }
            }
        }
        .chartXScale(domain: window)
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
                            Text("Rose \(store.format(i.earlyRise ?? i.rise)) in the first 90 minutes"
                                 + (i.exerciseEffect != nil ? ", allowing for exercise" : ""))
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
        if let ex = meal.exercise {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Label(ex.items.count == 1 ? ex.items[0].capitalizedFirst : "Exercise around this meal", systemImage: "figure.run")
                        .font(.headline)
                        .foregroundStyle(.teal)
                    fact(ex.effect >= 0 ? "Lowered glucose by" : "Raised glucose by", "about \(store.format(abs(ex.effect)))")
                    Text("The food score and the dose check allow for this.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder private var exerciseFacts: some View {
        let impact = store.exerciseImpact(entry.id)
        if let low = impact?.lowAfter {
            Label("Went down to \(store.format(low.mgdl)) at \(low.timestamp.formatted(date: .omitted, time: .shortened)), "
                  + "\(formatMinutes(Double(low.minutesAfter ?? 0))) after you finished. Exercise can lower glucose for many hours.",
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                fact("Intensity", entry.intensity?.capitalized ?? "–")
                if entry.isPlanned {
                    Text("Planned. Dose suggestions and low alerts allow for it, and how glucose responds shows here once it's done.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let i = impact {
                    if let start = i.startGlucose { fact("At the start", store.format(start)) }
                    if let end = i.endGlucose { fact(i.inProgress ? "Now" : "At the end", store.format(end)) }
                    if let change = i.change { fact("Change", formatDelta(change, mmol: store.useMmol)) }
                    fact("Typical drop for this activity", store.format(i.expectedDrop))
                    if let drop = i.exerciseDrop {
                        fact("Drop from the exercise", store.format(drop))
                            .help("The drop the exercise accounted for, once the carbs and insulin you logged are allowed for")
                    }
                    if let lowest = i.lowest {
                        fact(i.complete ? "Lowest in the 12 h after" : "Lowest since",
                             "\(store.format(lowest.mgdl)) at \(lowest.timestamp.formatted(date: .omitted, time: .shortened))")
                    }
                    if i.lowDuring { fact("During", "Went low") }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
