import SwiftUI

/// Menu bar labels are drawn as templates (monochrome), so render a non-template image to keep the color.
@MainActor
enum MenuBarLabel {
    static func image(for store: GlucoseStore) -> NSImage {
        let d = UserDefaults.standard
        let grey = store.color == .secondary
        let tint = grey ? Color.black : store.color

        let content: AnyView
        if d.bool(forKey: "dotWhenInRange"), store.isInRange, !store.isStale {
            content = AnyView(Circle().fill(tint).frame(width: 9, height: 9).padding(.horizontal, 2))
        } else {
            let points = d.bool(forKey: "showSparkline") ? store.history(lastHours: Double(d.integer(forKey: "sparklineHours"))) : []
            content = AnyView(HStack(spacing: 4) {
                if points.count > 1 {
                    Sparkline(points: points).stroke(tint.opacity(0.85), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                        .frame(width: 30, height: 13)
                }
                Text(store.title).font(.system(size: 13, weight: .medium)).monospacedDigit().foregroundStyle(tint)
            })
        }
        let renderer = ImageRenderer(content: content.frame(height: 18))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage()
        image.isTemplate = grey
        return image
    }
}

struct Sparkline: Shape {
    let points: [Point]

    func path(in rect: CGRect) -> Path {
        guard let first = points.first, let last = points.last, last.timestamp > first.timestamp else { return Path() }
        let lo = Double(min(points.map(\.mgdl).min()!, 70)), hi = Double(max(points.map(\.mgdl).max()!, 180))
        let span = last.timestamp.timeIntervalSince(first.timestamp)
        var path = Path()
        for (i, p) in points.enumerated() {
            let pt = CGPoint(x: rect.minX + rect.width * p.timestamp.timeIntervalSince(first.timestamp) / span,
                             y: rect.maxY - rect.height * (Double(p.mgdl) - lo) / (hi - lo))
            i == 0 ? path.move(to: pt) : path.addLine(to: pt)
        }
        return path
    }
}
