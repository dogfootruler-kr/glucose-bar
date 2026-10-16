import Foundation
import UserNotifications

/// Posts macOS notifications for low/high/fast-drop/no-data, repeating every 20 minutes while a condition lasts.
@MainActor
final class AlertManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    enum Condition: String, CaseIterable { case low, high, fastDrop, predictedLow, stale }

    @Published private(set) var snoozedUntil: Date?
    private var lastNotified: [Condition: Date] = [:]
    private let repeatInterval: TimeInterval = 20 * 60
    private let defaults = UserDefaults.standard
    private var center: UNUserNotificationCenter? {
        // UserNotifications crashes outside an app bundle (e.g. `swift run`).
        Bundle.main.bundleIdentifier == nil ? nil : .current()
    }

    override init() {
        super.init()
        let saved = defaults.double(forKey: "snoozedUntil")
        if saved > Date().timeIntervalSince1970 { snoozedUntil = Date(timeIntervalSince1970: saved) }
        guard let center else { return }
        center.delegate = self
        let snooze = UNNotificationAction(identifier: "SNOOZE", title: "Stop alerting for 30 min")
        center.setNotificationCategories([UNNotificationCategory(identifier: "GLUCOSE", actions: [snooze], intentIdentifiers: [])])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    var isSnoozed: Bool { (snoozedUntil ?? .distantPast) > Date() }

    func snooze(minutes: Double = 30) {
        snoozedUntil = Date().addingTimeInterval(minutes * 60)
        defaults.set(snoozedUntil!.timeIntervalSince1970, forKey: "snoozedUntil")
    }

    func cancelSnooze() {
        snoozedUntil = nil
        defaults.removeObject(forKey: "snoozedUntil")
    }

    func evaluate(reading: Reading?, forecast: Forecast?, stale: Bool, staleSince: Date) {
        let mmol = defaults.bool(forKey: "useMmol")
        var active: [Condition: (String, String)] = [:]
        if stale {
            let mins = Int(Date().timeIntervalSince(staleSince) / 60)
            active[.stale] = ("No glucose data", mins > 600 ? "No reading received yet." : "No new reading for \(mins) minutes. Check the sensor and phone.")
        } else if let r = reading {
            let value = "\(formatGlucose(r.mgdl, mmol: mmol)) \(r.arrow)"
            if r.mgdl <= defaults.integer(forKey: "alertLow") {
                active[.low] = ("Low glucose: \(value)", "Below your low alert.")
            } else if r.mgdl >= defaults.integer(forKey: "alertHigh") {
                active[.high] = ("High glucose: \(value)", "Above your high alert.")
            }
            if defaults.bool(forKey: "alertFastDrop"), [1, 2].contains(r.trend ?? 3), r.mgdl < 100, active[.low] == nil {
                active[.fastDrop] = ("Dropping fast: \(value)", "Glucose is falling quickly.")
            }
            if defaults.bool(forKey: "alertPredictedLow"), active[.low] == nil, active[.fastDrop] == nil,
               let hit = forecast?.crossing(below: defaults.integer(forKey: "alertLow")),
               hit.date.timeIntervalSinceNow <= 20 * 60 {
                let mins = max(1, Int(hit.date.timeIntervalSinceNow / 60))
                active[.predictedLow] = ("Heading low: \(value)",
                                         "Projected to reach \(formatGlucose(hit.mgdl, mmol: mmol)) in about \(mins) min (\(hit.date.formatted(date: .omitted, time: .shortened))).")
            }
        }

        for c in Condition.allCases where active[c] == nil { lastNotified[c] = nil }
        guard defaults.bool(forKey: "alertsEnabled"), !isSnoozed else { return }
        for (c, (title, body)) in active where Date().timeIntervalSince(lastNotified[c] ?? .distantPast) > repeatInterval {
            lastNotified[c] = Date()
            post(id: c.rawValue, title: title, body: body)
        }
    }

    func sendTest() {
        post(id: "test", title: "Test alert", body: "Notifications from GlucoseBar are working.")
    }

    func post(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = "GLUCOSE"
        center?.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        if response.actionIdentifier == "SNOOZE" {
            await MainActor.run { snooze() }
        }
    }
}
