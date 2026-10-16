import SwiftUI
import UniformTypeIdentifiers

struct LogView: View {
    @ObservedObject var store: GlucoseStore
    @Environment(\.dismiss) private var dismiss
    @State private var kind = "meal"
    @State private var time = Date()
    @State private var note = ""
    // meal
    @State private var photo: NSImage?
    @State private var carbs: Double?
    @State private var estimate: MealEstimate?
    @State private var estimating = false
    // insulin
    @State private var units: Double = 1
    @State private var insulinType = "rapid"
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Picker("", selection: $kind) {
                    Label("Meal", systemImage: "fork.knife").tag("meal")
                    Label("Insulin", systemImage: "syringe").tag("insulin")
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if kind == "meal" { mealFields } else { insulinFields }

                DatePicker("Time", selection: $time, in: ...Date().addingTimeInterval(3600))
                if let error {
                    Text(error).foregroundStyle(.red).font(.caption)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(saving ? "Saving…" : "Save") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || (kind == "meal" && carbs == nil && note.isEmpty && photo == nil))
            }
            .padding([.horizontal, .bottom])

            RecentEntries(store: store)
        }
        .frame(width: 420)
        .onAppear { time = Date() }
    }

    @ViewBuilder private var mealFields: some View {
        Section {
            PhotoWell(image: $photo)
            TextField("What did you eat?", text: $note, prompt: Text("e.g. Kimchi jjigae with rice"))
            HStack {
                Button {
                    Task { await runEstimate() }
                } label: {
                    if estimating { ProgressView().controlSize(.small) } else { Label("Estimate carbs with Claude", systemImage: "sparkles") }
                }
                .disabled(estimating || !store.aiAvailable || (photo == nil && note.isEmpty))
                if !store.aiAvailable {
                    Text("Add an Anthropic API key to enable").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let estimate {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(estimate.items, id: \.name) { item in
                        HStack { Text(item.name); Spacer(); Text("\(Int(item.carbs)) g").monospacedDigit() }
                    }
                    Text("Confidence: \(estimate.confidence)" + (estimate.note.map { " · \($0)" } ?? ""))
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }
            TextField("Carbs (g)", value: $carbs, format: .number)
        }
    }

    @ViewBuilder private var insulinFields: some View {
        Section {
            HStack {
                TextField("Units", value: $units, format: .number)
                Stepper("", value: $units, in: 0...100, step: 0.5).labelsHidden()
            }
            Picker("Type", selection: $insulinType) {
                Text("Rapid-acting").tag("rapid")
                Text("Long-acting").tag("long")
            }
            TextField("Note", text: $note, prompt: Text("Optional"))
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
        var event = GlucoseStore.NewEvent(kind: kind, timestamp: time, note: note.isEmpty ? nil : note)
        if kind == "meal" {
            event.carbs = carbs
            event.estimate = estimate
            if let photo, let data = jpegData(photo) {
                event.photo = data.base64EncodedString()
                event.mediaType = "image/jpeg"
            }
        } else {
            event.units = units
            event.insulinType = insulinType
        }
        do {
            try await store.addEvent(event)
            reset()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func reset() {
        note = ""; photo = nil; carbs = nil; estimate = nil; units = 1; time = Date()
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
    @State private var targeted = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: image == nil ? [4] : []))
                    .foregroundStyle(targeted ? Color.accentColor : .secondary)
                if let image {
                    Image(nsImage: image).resizable().scaledToFill().frame(width: 72, height: 72).clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Image(systemName: "camera").font(.title2).foregroundStyle(.secondary)
                }
            }
            .frame(width: 72, height: 72)
            .onDrop(of: [.image, .fileURL], isTargeted: $targeted) { providers in
                load(providers)
                return true
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(image == nil ? "Drop a photo of the meal" : "Photo added").font(.callout)
                HStack {
                    Button("Choose…", action: choose)
                    Button("Paste", action: paste)
                    if image != nil { Button("Remove") { image = nil } }
                }
                .controlSize(.small)
            }
        }
    }

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

struct RecentEntries: View {
    @ObservedObject var store: GlucoseStore

    var body: some View {
        let recent = store.recentEvents.reversed()
        if !recent.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Last 24 hours").font(.caption.bold()).foregroundStyle(.secondary)
                ForEach(Array(recent)) { e in
                    HStack {
                        Image(systemName: e.isMeal ? "fork.knife" : "syringe").frame(width: 16)
                        Text(e.timestamp.formatted(date: .omitted, time: .shortened)).monospacedDigit().foregroundStyle(.secondary)
                        Text(e.label).lineLimit(1)
                        Spacer()
                        Button { Task { await store.deleteEvent(e.id) } } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .help("Delete")
                    }
                    .font(.caption)
                }
            }
            .padding([.horizontal, .bottom])
        }
    }
}
