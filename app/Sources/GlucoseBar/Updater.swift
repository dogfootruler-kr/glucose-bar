import Foundation

/// Runs the update agent that install.sh sets up, which installs the latest GitHub release
/// (and then quits and reopens this app) when it's newer than the installed one.
enum Updater {
    static let label = "co.dnk.freestyle-bar.update"
    static let api = URL(string: "https://api.github.com/repos/dogfootruler-kr/glucose-bar/releases/latest")!

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

    struct Release: Decodable {
        let tag: String
        let notes: String
        enum CodingKeys: String, CodingKey { case tag = "tag_name", notes = "body" }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            tag = try c.decode(String.self, forKey: .tag)
            notes = ((try? c.decode(String.self, forKey: .notes)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// The latest release, with its notes (the CHANGELOG.md section for that version).
    static func latest() async -> Release? {
        guard let (data, response) = try? await URLSession.shared.data(from: api),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(Release.self, from: data)
    }
}
