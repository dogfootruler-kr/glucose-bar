import AppKit
import SwiftUI

/// GlucoseBar is a menu bar app (LSUIElement), so macOS opens its windows behind whatever app is
/// active. While one of its windows is open it becomes a regular app (Dock icon, ⌘-Tab) and each
/// window is brought to the front when it opens or is asked for again; it goes back to being a
/// menu bar app when the last one closes.
@MainActor
enum WindowActivation {
    private static var windows: [String: NSWindow] = [:]

    static func register(_ window: NSWindow, as id: String) {
        guard windows[id] !== window else { return }
        windows[id] = window
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated {
                if windows[id] === window { windows[id] = nil }
                if windows.isEmpty { NSApp.setActivationPolicy(.accessory) }
            }
        }
        bringForward(window)
    }

    /// Call right after openWindow/openSettings: the window may already exist, or appear a moment later.
    static func bringForward(id: String) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if let window = windows[id] { bringForward(window) }
        }
    }

    private static func bringForward(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}

extension View {
    /// Brings this view's window to the front when it opens and tracks it for `WindowActivation`.
    func activatesWindow(_ id: String) -> some View {
        background(WindowReader { WindowActivation.register($0, as: id) })
    }
}

struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = TrackingView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class TrackingView: NSView {
        var onWindow: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }
}

/// MenuBarExtra's panel can keep a stale height after the popup's content changes while it is
/// closed (a forecast line or error appearing, a meal row going away), which shows up as transparent
/// bands above and below the content. Refit the panel to its content each time it opens.
@MainActor
enum PopupFitter {
    private static weak var tracked: NSWindow?

    static func track(_ window: NSWindow) {
        guard tracked !== window else { return }
        tracked = window
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated {
                fit(window)
                // SwiftUI may still be updating the content (relative times, new readings) as it opens.
                DispatchQueue.main.async { fit(window) }
            }
        }
    }

    private static func fit(_ window: NSWindow) {
        guard let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        guard size.height > 0 else { return }
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        if frame != window.frame { window.setFrame(frame, display: true) }
    }
}

/// Opens the app's windows from anywhere, in front of other apps.
@MainActor
struct WindowOpener {
    let openWindow: OpenWindowAction
    let openSettings: OpenSettingsAction

    func callAsFunction(_ id: String) {
        if id == "settings" { openSettings() } else { openWindow(id: id) }
        WindowActivation.bringForward(id: id)
    }

    func edit(_ eventID: Int) {
        openWindow(id: "edit", value: eventID)
        WindowActivation.bringForward(id: "edit-\(eventID)")
    }
}

extension EnvironmentValues {
    @MainActor var windowOpener: WindowOpener { WindowOpener(openWindow: openWindow, openSettings: openSettings) }
}
