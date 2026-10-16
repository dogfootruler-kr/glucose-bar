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

        Settings {
            SettingsView(store: store)
        }
    }
}
