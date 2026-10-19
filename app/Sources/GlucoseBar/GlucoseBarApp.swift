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

        Window("New Entry", id: "log") {
            EntryEditor(store: store).activatesWindow("log")
        }
        .windowResizability(.contentSize)

        WindowGroup("Edit Entry", id: "edit", for: Int.self) { $id in
            EditEntryWindow(store: store, id: id)
        }
        .windowResizability(.contentSize)

        Window("Journal", id: "journal") {
            JournalView(store: store)
        }
        .defaultSize(width: 860, height: 600)

        Window("Weekly Summary", id: "summary") {
            SummaryView(store: store)
        }
        .defaultSize(width: 560, height: 640)

        Settings {
            SettingsView(store: store)
        }
    }
}
