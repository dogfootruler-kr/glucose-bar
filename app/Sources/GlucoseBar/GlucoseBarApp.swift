import SwiftUI

@main
struct GlucoseBarApp: App {
    @StateObject private var store = GlucoseStore()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(store: store, alerts: store.alerts)
        } label: {
            Image(nsImage: MenuBarLabel.image(for: store))
        }
        .menuBarExtraStyle(.window)

        Window("Log meal or insulin", id: "log") {
            LogView(store: store)
        }
        .windowResizability(.contentSize)

        Window("Meals", id: "meals") {
            MealsView(store: store)
        }

        Window("Weekly Summary", id: "summary") {
            SummaryView(store: store)
        }

        Settings {
            SettingsView(store: store)
        }
    }
}
