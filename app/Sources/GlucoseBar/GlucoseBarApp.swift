import SwiftUI

@main
struct GlucoseBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var app
    private var store: GlucoseStore { app.store }

    init() {
        // Without this macOS tints windows with the part of the wallpaper behind them, so each
        // window comes out a different colour depending on where it sits.
        UserDefaults.standard.register(defaults: ["AppleReduceDesktopTinting": true])
        Updater.run()  // check for a newer release on every launch
    }

    var body: some Scene {
        Window("New Entry", id: "log") {
            EntryEditor(store: store).activatesWindow("log")
        }
        .windowResizability(.contentSize)
        // The Meal / Insulin / Exercise picker takes the title's place; with both it overflows.
        .windowToolbarStyle(.unified(showsTitle: false))

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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = GlucoseStore()
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = StatusItemController(store: store)
        // Windows SwiftUI opens by itself at launch arrive before this runs; let later ones through.
        DispatchQueue.main.async { WindowActivation.launched = true }
    }
}
