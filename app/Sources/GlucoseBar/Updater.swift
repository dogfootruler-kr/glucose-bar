import Foundation

/// Runs the update agent that install.sh sets up, which installs the latest GitHub release
/// (and then quits and reopens this app) when it's newer than the installed one.
enum Updater {
    static let label = "co.dnk.freestyle-bar.update"
    static let releases = URL(string: "https://github.com/dogfootruler-kr/glucose-bar/releases/latest")!

    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }
    static var isDev: Bool { version == "dev" }

    /// Starts the agent now; false when it isn't installed.
    @discardableResult
    static func run() -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["kickstart", "gui/\(getuid())/\(label)"]
        guard (try? task.run()) != nil else { return false }
        task.waitUntilExit()
        return task.terminationStatus == 0
    }

    /// The latest release's tag, read from where GitHub redirects /releases/latest.
    static func latest() async -> String? {
        var req = URLRequest(url: releases)
        req.httpMethod = "HEAD"
        guard let (_, response) = try? await URLSession.shared.data(for: req),
              let tag = response.url?.lastPathComponent, tag.hasPrefix("v") else { return nil }
        return tag
    }
}
