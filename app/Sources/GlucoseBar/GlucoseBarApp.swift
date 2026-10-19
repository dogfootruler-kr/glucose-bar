import SwiftUI

@main
struct GlucoseBarApp: App {
    @StateObject private var store = GlucoseStore()

    init() {
        // Without this macOS tints windows with the part of the wallpaper behind them, so each
        // window comes out a different colour depending on where it sits.
        UserDefaults.standard.register(defaults: ["AppleReduceDesktopTinting": true])
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(store: store, alerts: store.alerts)
        } label: {
            Image(nsImage: MenuBarLabel.image(for: store))
        }
        .menuBarExtraStyle(.window)

        Window("New Entry", id: "log") {
            EntryEditor(store: store).activatesWindow("log")
        }
        .windowResizability(.contentSize)
        .windowToolbarStyle(.unified)

        WindowGroup("Edit Entry", id: "edit", for: Int.self) { $id in
            EditEntryWindow(store: store, id: id)
        }
        .windowResizability(.contentSize)
        .windowToolbarStyle(.unified)

        Window("Journal", id: "journal") {
            JournalView(store: store)
        }
        .defaultSize(width: 860, height: 600)
        .windowToolbarStyle(.unified)

        Window("Weekly Summary", id: "summary") {
            SummaryView(store: store)
        }
        .defaultSize(width: 560, height: 640)
        .windowToolbarStyle(.unified)

        Settings {
            SettingsView(store: store)
        }
    }
}
