import SwiftUI
import UniformTypeIdentifiers

/// Adds a meal, insulin or exercise entry, or changes an existing one.
struct EntryEditor: View {
    @ObservedObject var store: GlucoseStore
    let existing: GlucoseEvent?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.controlActiveState) private var activeState

    @State private var kind: String
    @State private var time: Date
    @State private var timeEdited = false
    @State private var note: String
    // meal
    @State private var photo: NSImage?
    @State private var keepsPhoto: Bool
    @State private var carbs: Double?
    @State private var estimate: MealEstimate?
    @State private var estimating = false
    // insulin
    @State private var units: Double
    @State private var insulinType: String
    // exercise
    @State private var activity: String
    @State private var minutes: Double
    @State private var intensity: String
    // insulin logged together with a new meal
    @State private var suggestion: DoseSuggestion?
    @State private var suggestionError: String?
    @State private var logDose = false
    @State private var doseUnits: Double = 0
    @State private var doseEdited = false

    @State private var error: String?
    @State private var saving = false
    @State private var confirmDelete = false

    init(store: GlucoseStore, existing: GlucoseEvent? = nil) {
        self.store = store
        self.existing = existing
        _kind = State(initialValue: existing?.kind ?? "meal")
        _time = State(initialValue: existing?.timestamp ?? Date())
        _note = State(initialValue: existing?.note ?? "")
        _keepsPhoto = State(initialValue: existing?.photo != nil)
        _carbs = State(initialValue: existing?.carbs)
        _estimate = State(initialValue: existing?.estimate)
        _units = State(initialValue: existing?.units ?? 1)
        _insulinType = State(initialValue: existing?.insulinType ?? "rapid")
        _activity = State(initialValue: existing?.activity ?? "walk")
        _minutes = State(initialValue: existing?.minutes ?? 30)
        _intensity = State(initialValue: existing?.intensity ?? "moderate")
    }

    private var isMeal: Bool { kind == "meal" }
    private var isExercise: Bool { kind == "exercise" }

    /// Exercise can be planned a few hours ahead; meals and insulin up to an hour.
    private var latest: Date { Date().addingTimeInterval(isExercise ? 6 * 3600 : 3600) }

    /// Suggestions are for eating now, so they're hidden when logging something from earlier.
    private var suggestsDose: Bool { existing == nil && isMeal && abs(time.timeIntervalSinceNow) < 30 * 60 }

    private var canSave: Bool {
        guard !saving else { return false }
        switch kind {
        case "meal": return carbs != nil || !note.isEmpty || photo != nil || keepsPhoto
        case "exercise": return minutes > 0
        default: return units > 0
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                switch kind {
                case "meal": mealSections
                case "exercise": exerciseSection
                default: insulinSection
                }
                Section {
                    DatePicker(isExercise ? "Starts" : "Time", selection: Binding { time } set: { time = $0; timeEdited = true }, in: ...latest)
                } footer: {
                    if isExercise && time > Date() {
                        Text("Planned: dose suggestions and low alerts will allow for it.")
                    }
                }
                if isMeal && existing == nil { doseSection }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if existing != nil {
                    Button("Delete…", role: .destructive) { confirmDelete = true }
                }
                Spacer()
                Button("Cancel") { timeEdited = false; dismiss() }.keyboardShortcut(.cancelAction)
                Button(existing == nil ? "Add" : "Save") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding(16)
        }
        .frame(width: 460)
        .frame(minHeight: 420, idealHeight: isMeal ? 680 : isExercise ? 470 : 420)
        .confirmationDialog("Delete this entry?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                Task {
                    if let existing { await store.deleteEvent(existing.id) }
                    dismiss()
                }
            }
        } message: {
            Text("This can't be undone.")
        }
        .toolbar {
            if existing == nil {
                ToolbarItem(placement: .principal) {
                    Picker("Entry", selection: $kind) {
                        Text("Meal").tag("meal")
                        Text("Insulin").tag("insulin")
                        Text("Exercise").tag("exercise")
                    }
                    .pickerStyle(.segmented)
                }
            }
        }
        // The window keeps its state between uses, so a new entry starts at the current time each
        // time it comes forward unless the time was picked by hand.
        .onAppear { refreshTime() }
        .onChange(of: kind) { if time > latest { time = Date(); timeEdited = false } }
        .onChange(of: activeState) { if activeState == .key { refreshTime() } }
        .task(id: suggestsDose ? carbs ?? 0 : -1) { await loadSuggestion() }
    }

    // MARK: meal

    @ViewBuilder private var mealSections: some View {
        Section {
            if existing == nil, !store.previousMeals.isEmpty { previousMealPicker }
            PhotoWell(image: $photo, existing: keepsPhoto ? existing?.photo : nil) { keepsPhoto = false }
            TextField("Description", text: $note, prompt: Text("e.g. Kimchi jjigae with rice"))
            LabeledContent("Carbs") {
                HStack(spacing: 4) {
                    TextField("Carbs", value: $carbs, format: .number, prompt: Text("0"))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 64)
                    Text("g").foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Meal")
        }

        Section {
            Button {
                Task { await runEstimate() }
            } label: {
                HStack {
                    Label("Estimate Carbs with Claude", systemImage: "sparkles")
                    if estimating {
                        Spacer()
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .disabled(estimating || !store.aiAvailable || (photo == nil && note.isEmpty))
            if let estimate {
                ForEach(estimate.items, id: \.name) { item in
                    LabeledContent(item.name, value: "\(Int(item.carbs)) g")
                }
                LabeledContent("Confidence", value: estimate.confidence.capitalized)
            }
        } footer: {
            if !store.aiAvailable {
                Text("Claude is unavailable. Run `claude` once on the server Mac to log in.")
            } else if let note = estimate?.note {
                Text(note)
            } else {
                Text("Uses the photo and description.")
            }
        }
    }

    private var previousMealPicker: some View {
        Menu {
            ForEach(store.previousMeals.prefix(25)) { meal in
                Button { usePrevious(meal) } label: {
                    Text(meal.note ?? "Meal")
                    Text(([meal.carbs.map { "\(Int($0)) g carbs" }]
                          + [meal.timestamp.formatted(.relative(presentation: .named))]).compactMap { $0 }.joined(separator: " · "))
                }
            }
        } label: {
            Label("Same as a Previous Meal", systemImage: "clock.arrow.circlepath")
        }
    }

    @ViewBuilder private var doseSection: some View {
        Section {
            if let ex = store.exercise(near: time) {
                Label(ex.isPlanned ? "\(ex.title), planned for \(ex.timestamp.formatted(date: .omitted, time: .shortened))"
                                   : "\(ex.title), \(ex.end > Date() ? "in progress" : "ended \(ex.end.formatted(.relative(presentation: .named)))")",
                      systemImage: ex.symbol)
                    .foregroundStyle(ex.tint)
            }
            if suggestsDose, (carbs ?? 0) > 0 {
                if let s = suggestion {
                    DoseSuggestionView(store: store, suggestion: s, carbs: carbs ?? 0)
                } else if let suggestionError {
                    Text(suggestionError).foregroundStyle(.secondary)
                } else {
                    HStack { Text("Working out a dose…").foregroundStyle(.secondary); Spacer(); ProgressView().controlSize(.small) }
                }
            }
            Toggle("Also log rapid insulin", isOn: $logDose)
            if logDose {
                Stepper(value: Binding(get: { doseUnits }, set: { doseUnits = $0; doseEdited = true }), in: 0...50, step: 0.5) {
                    LabeledContent("Units", value: "\(formatUnits(doseUnits)) u")
                }
            }
        } header: {
            Text("Rapid Insulin")
        } footer: {
            if suggestsDose, (carbs ?? 0) > 0, suggestion != nil {
                Text("An estimate from your own logs, not medical advice. Check it against what your diabetes team has told you.")
            }
        }
    }

    // MARK: insulin

    private var insulinSection: some View {
        Section("Insulin") {
            Picker("Type", selection: $insulinType) {
                Text("Rapid-acting").tag("rapid")
                Text("Long-acting").tag("long")
            }
            LabeledContent("Units") {
                HStack(spacing: 6) {
                    TextField("Units", value: $units, format: .number)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 56)
                    Stepper("Units", value: $units, in: 0...100, step: 0.5).labelsHidden()
                }
            }
            TextField("Note", text: $note, prompt: Text("Optional"))
        }
    }

    // MARK: exercise

    private var exerciseSection: some View {
        Section("Exercise") {
            Picker("Activity", selection: $activity) {
                ForEach(Activity.allCases, id: \.self) { Label($0.name, systemImage: $0.symbol).tag($0.rawValue) }
            }
            LabeledContent("Duration") {
                HStack(spacing: 6) {
                    TextField("Duration", value: $minutes, format: .number)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 56)
                    Text("min").foregroundStyle(.secondary)
                    Stepper("Duration", value: $minutes, in: 0...600, step: 5).labelsHidden()
                }
            }
            Picker("Intensity", selection: $intensity) {
                ForEach(intensities, id: \.self) { Text($0.capitalized).tag($0) }
            }
            TextField("Note", text: $note, prompt: Text("Optional"))
        }
    }

    // MARK: actions

    private func loadSuggestion() async {
        guard suggestsDose, let carbs, carbs > 0 else { return }
        try? await Task.sleep(for: .milliseconds(400))  // typing
        guard !Task.isCancelled else { return }
        do {
            let s = try await store.doseSuggestion(carbs: carbs)
            suggestion = s
            suggestionError = nil
            if !doseEdited { doseUnits = s.units }
        } catch {
            suggestion = nil
            suggestionError = error.localizedDescription
        }
    }

    /// Fills in a previous meal's description, carbs, estimate and photo; the time stays now.
    private func usePrevious(_ meal: GlucoseEvent) {
        note = meal.note ?? ""
        carbs = meal.carbs
        estimate = meal.estimate
        photo = nil
        error = nil
        guard let path = meal.photo else { return }
        Task {
            let image = await store.photo(path)
            if note == meal.note, photo == nil { photo = image }
        }
    }

    private func runEstimate() async {
        estimating = true
        error = nil
        defer { estimating = false }
        do {
            let result = try await store.estimateMeal(photoJPEG: photo.flatMap { jpegData($0) }, text: note.isEmpty ? nil : note)
            estimate = result
            carbs = result.carbs.rounded()
            if note.isEmpty { note = result.description }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func save() async {
        saving = true
        error = nil
        defer { saving = false }
        do {
            if let existing {
                try await store.updateEvent(existing.id, change(for: existing))
            } else {
                try await add()
            }
            if existing == nil { reset() }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func add() async throws {
        var event = GlucoseStore.NewEvent(kind: kind, timestamp: time, note: note.isEmpty ? nil : note)
        switch kind {
        case "meal":
            event.carbs = carbs
            event.estimate = estimate
            if let photo, let data = jpegData(photo) {
                event.photo = data.base64EncodedString()
                event.mediaType = "image/jpeg"
            }
        case "exercise":
            event.activity = activity
            event.minutes = minutes
            event.intensity = intensity
        default:
            event.units = units
            event.insulinType = insulinType
        }
        try await store.addEvent(event)
        if isMeal, logDose, doseUnits > 0 {
            try await store.addEvent(.init(kind: "insulin", timestamp: time, units: doseUnits, insulinType: "rapid"))
        }
    }

    private func change(for existing: GlucoseEvent) -> GlucoseStore.EventChange {
        var c = GlucoseStore.EventChange(timestamp: time, note: note)
        switch kind {
        case "meal":
            if let carbs { c.carbs = carbs } else { c.clearCarbs = true }
            if estimate != existing.estimate { c.estimate = estimate }
            if let photo, let data = jpegData(photo) {
                c.photo = data.base64EncodedString()
                c.mediaType = "image/jpeg"
            } else if existing.photo != nil && !keepsPhoto {
                c.removePhoto = true
            }
        case "exercise":
            c.activity = activity
            c.minutes = minutes
            c.intensity = intensity
        default:
            c.units = units
            c.insulinType = insulinType
        }
        return c
    }

    private func refreshTime() {
        if existing == nil && !timeEdited { time = Date() }
    }

    private func reset() {
        note = ""; photo = nil; carbs = nil; estimate = nil; units = 1; time = Date(); timeEdited = false
        activity = "walk"; minutes = 30; intensity = "moderate"
        suggestion = nil; logDose = false; doseEdited = false
    }
}

/// The suggested dose with how it was worked out.
struct DoseSuggestionView: View {
    @ObservedObject var store: GlucoseStore
    let suggestion: DoseSuggestion
    let carbs: Double
    @State private var expanded = false

    var body: some View {
        let s = suggestion
        LabeledContent {
            Text("\(formatUnits(s.units)) u").font(.title2.weight(.semibold)).monospacedDigit()
        } label: {
            Text("Suggested dose")
            Text(basis)
        }
        ForEach([s.warning, s.exercise?.warning].compactMap { $0 }, id: \.self) { warning in
            Label(warning, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        DisclosureGroup("How it's worked out", isExpanded: $expanded) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                step("\(Int(carbs)) g at 1 u per \(formatUnits(s.periodCarbRatio)) g (\(s.period))", s.carbUnits)
                if let g = s.glucose {
                    step("Now \(store.format(g)), target \(store.format(s.target)), 1 u per \(store.format(s.sensitivity))", s.correctionUnits)
                }
                if s.trendUnits != 0 { step("Where the trend is heading in 30 min", s.trendUnits) }
                if s.activeDeducted > 0 {
                    step("Insulin still active: \(formatUnits(s.activeInsulin)) u, less what \(s.carbsOnBoard) g still digesting needs", -s.activeDeducted)
                }
                if let ex = s.exercise { step(ex.label, -ex.units) }
                Divider().gridCellUnsizedAxes(.horizontal)
                GridRow {
                    Text("Rounded down to the nearest half unit").foregroundStyle(.secondary)
                    Text("\(formatUnits(s.units)) u").bold().gridColumnAlignment(.trailing)
                }
            }
            .font(.callout)
            .monospacedDigit()
            .padding(.vertical, 4)
        }
    }

    private var basis: String {
        let s = suggestion
        if s.meals < 3 {
            return "Mostly the usual rules for your \(formatUnits(s.dailyDose)) u a day, until more meals are logged"
        }
        return "Learned from \(s.meals) meals over \(Int(s.days.rounded())) days"
    }

    private func step(_ label: String, _ units: Double) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text((units >= 0 ? "+" : "−") + formatUnits(abs(units)) + " u").gridColumnAlignment(.trailing)
        }
    }
}

/// JPEG, longest side at most 1568 px (what the API uses anyway).
func jpegData(_ image: NSImage, maxSide: CGFloat = 1568) -> Data? {
    guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    let scale = min(1, maxSide / CGFloat(max(cg.width, cg.height)))
    let w = Int(CGFloat(cg.width) * scale), h = Int(CGFloat(cg.height) * scale)
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    ctx.interpolationQuality = .high
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let resized = ctx.makeImage() else { return nil }
    return NSBitmapImageRep(cgImage: resized).representation(using: .jpeg, properties: [.compressionFactor: 0.85])
}

struct PhotoWell: View {
    @Binding var image: NSImage?
    /// Server path of a photo already saved with the entry.
    var existing: String?
    var onRemoveExisting: () -> Void = {}
    @State private var targeted = false

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.quaternary.opacity(0.5))
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: hasPhoto ? [] : [4]))
                    .foregroundStyle(targeted ? Color.accentColor : Color.secondary.opacity(0.5))
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else if let existing, let url = URL(string: existing, relativeTo: GlucoseStore.server) {
                    AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { ProgressView().controlSize(.small) }
                } else {
                    Image(systemName: "camera").font(.title2).foregroundStyle(.secondary)
                }
            }
            .frame(width: 76, height: 76)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .onDrop(of: [.image, .fileURL], isTargeted: $targeted) { providers in
                load(providers)
                return true
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(hasPhoto ? "Photo" : "Drop a photo of the meal").foregroundStyle(hasPhoto ? .primary : .secondary)
                HStack {
                    Button(hasPhoto ? "Replace…" : "Choose…", action: choose)
                    Button("Paste", action: paste)
                    if hasPhoto {
                        Button("Remove") { image = nil; onRemoveExisting() }
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    private var hasPhoto: Bool { image != nil || existing != nil }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK, let url = panel.url { image = NSImage(contentsOf: url) }
    }

    private func paste() {
        if let img = NSImage(pasteboard: .general) { image = img }
    }

    private func load(_ providers: [NSItemProvider]) {
        for p in providers {
            if p.canLoadObject(ofClass: NSImage.self) {
                _ = p.loadObject(ofClass: NSImage.self) { obj, _ in
                    if let img = obj as? NSImage { DispatchQueue.main.async { image = img } }
                }
                return
            }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url, let img = NSImage(contentsOf: url) { DispatchQueue.main.async { image = img } }
            }
        }
    }
}

/// The edit window for one entry, opened from the menu bar popup.
struct EditEntryWindow: View {
    @ObservedObject var store: GlucoseStore
    let id: Int?

    var body: some View {
        Group {
            if let id, let entry = store.entry(id) {
                EntryEditor(store: store, existing: entry).id(entry.id)
            } else {
                ContentUnavailableView("Entry not found", systemImage: "questionmark.circle",
                                       description: Text("It may have been deleted, or is older than 30 days."))
                    .frame(width: 360, height: 240)
            }
        }
        .activatesWindow("edit-\(id ?? 0)")
    }
}
