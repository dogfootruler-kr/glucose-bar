import AppKit
import Combine
import SwiftUI

/// The menu bar item and its popup. MenuBarExtra's panel keeps a stale height when the popup's
/// content changes while it is closed, which shows as transparent bands around the content, so
/// this uses an NSPopover whose hosting controller resizes it to the content as it changes.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let store: GlucoseStore
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var observers: Set<AnyCancellable> = []

    init(store: GlucoseStore) {
        self.store = store
        super.init()

        let content = MenuContent(store: store, alerts: store.alerts)
            .environment(\.closePopup) { [weak self] in self?.popover.performClose(nil) }
        let host = NSHostingController(rootView: content)
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient
        // Animated resizes can loop in layout on recent macOS, and the content changes size as it updates.
        popover.animates = false
        popover.delegate = self

        item.button?.target = self
        item.button?.action = #selector(toggle)
        updateLabel()
        // objectWillChange fires before the change lands, so draw on the next pass.
        store.objectWillChange
            .merge(with: NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).map { _ in })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.updateLabel() }
            .store(in: &observers)
    }

    private func updateLabel() {
        item.button?.image = MenuBarLabel.image(for: store)
    }

    @objc private func toggle() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = item.button else { return }
        NSApp.activate()  // so the popup takes clicks and closes when another app is clicked
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        if let window = popover.contentViewController?.view.window {
            // Show over another app's full-screen Space too.
            window.collectionBehavior.remove(.moveToActiveSpace)
            window.collectionBehavior.insert([.canJoinAllSpaces, .fullScreenAuxiliary])
            window.makeFirstResponder(nil)  // no focus ring on the first control
        }
    }
}

extension EnvironmentValues {
    /// Closes the menu bar popup.
    @Entry var closePopup: () -> Void = {}
}
