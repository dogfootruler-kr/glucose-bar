import SwiftUI

struct MealsView: View {
    @ObservedObject var store: GlucoseStore
    @State private var sort = "recent"

    private var sorted: [Meal] {
        switch sort {
        case "best": store.meals.filter { $0.impact != nil }.sorted { $0.impact!.score > $1.impact!.score }
        case "worst": store.meals.filter { $0.impact != nil }.sorted { $0.impact!.score < $1.impact!.score }
        default: store.meals.reversed()
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $sort) {
                Text("Recent").tag("recent")
                Text("Easiest on glucose").tag("best")
                Text("Hardest on glucose").tag("worst")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding()
            if store.meals.isEmpty {
                ContentUnavailableView("No meals yet", systemImage: "fork.knife",
                                       description: Text("Log a meal with the + button. Its glucose impact appears here over the next 3 hours."))
            } else {
                List(sorted) { meal in
                    MealRow(meal: meal, store: store, compact: false)
                        .contextMenu {
                            Button("Delete", role: .destructive) { Task { await store.deleteEvent(meal.id) } }
                        }
                }
            }
        }
        .frame(minWidth: 460, minHeight: 420)
    }
}

struct MealRow: View {
    let meal: Meal
    @ObservedObject var store: GlucoseStore
    let compact: Bool

    var body: some View {
        HStack(spacing: 10) {
            thumbnail
            VStack(alignment: .leading, spacing: 2) {
                Text(meal.note ?? "Meal").lineLimit(1).font(compact ? .caption : .body)
                Text(details).font(.caption2).foregroundStyle(.secondary).lineLimit(compact ? 1 : 2)
            }
            Spacer()
            badge
        }
    }

    private var details: String {
        var parts = [meal.timestamp.formatted(compact ? .dateTime.hour().minute() : .dateTime.weekday().day().month().hour().minute())]
        if let c = meal.carbs { parts.append("\(Int(c)) g") }
        if let i = meal.impact {
            parts.append("+\(store.format(i.rise)) peak at \(i.minutesToPeak) min")
            if !compact {
                if i.minutesAboveHigh > 0 { parts.append("\(i.minutesAboveHigh) min above range") }
                if let b = i.minutesToBaseline { parts.append("back to start after \(b) min") }
            }
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var thumbnail: some View {
        let size: CGFloat = compact ? 28 : 44
        if let photo = meal.photo, let url = URL(string: photo, relativeTo: GlucoseStore.server) {
            AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { Color.secondary.opacity(0.2) }
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            Image(systemName: "fork.knife")
                .frame(width: size, height: size)
                .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    @ViewBuilder private var badge: some View {
        if let i = meal.impact {
            VStack(spacing: 0) {
                Text("\(i.score)").font((compact ? Font.caption : .title3).bold()).monospacedDigit()
                if !i.complete { Text("so far").font(.system(size: 8)) }
            }
            .foregroundStyle(i.score >= 80 ? .green : i.score >= 50 ? .orange : .red)
            .help("Score 0–100: how gently glucose responded (rise and time above range)")
        } else {
            Text("–").foregroundStyle(.secondary)
        }
    }
}
