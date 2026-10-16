import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: GlucoseStore
    @AppStorage("useMmol") private var useMmol = false
    @AppStorage("targetLow") private var targetLow = 70
    @AppStorage("targetHigh") private var targetHigh = 180
    @AppStorage("showDelta") private var showDelta = true
    @AppStorage("showSparkline") private var showSparkline = true
    @AppStorage("sparklineHours") private var sparklineHours = 2
    @AppStorage("dotWhenInRange") private var dotWhenInRange = false
    @AppStorage("alertsEnabled") private var alertsEnabled = true
    @AppStorage("alertLow") private var alertLow = 70
    @AppStorage("alertHigh") private var alertHigh = 250
    @AppStorage("alertFastDrop") private var alertFastDrop = true
    @AppStorage("staleMinutes") private var staleMinutes = 20
    @AppStorage("sensorDays") private var sensorDays = 14
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var shareOnLAN = ServerConfig.lan

    var body: some View {
        TabView {
            Form {
                Picker("Units", selection: $useMmol) {
                    Text("mg/dL").tag(false)
                    Text("mmol/L").tag(true)
                }
                glucoseStepper("Target low", $targetLow, 50...targetHigh - 10)
                glucoseStepper("Target high", $targetHigh, targetLow + 10...300)
                Picker("Sensor lifetime", selection: $sensorDays) {
                    Text("14 days").tag(14)
                    Text("15 days (Libre 3 Plus)").tag(15)
                }
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                    }
            }
            .tabItem { Label("General", systemImage: "gear") }

            Form {
                Toggle("Show change since 5 min ago (+8)", isOn: $showDelta)
                Toggle("Show trend line", isOn: $showSparkline)
                Picker("Trend line covers", selection: $sparklineHours) {
                    ForEach(1...3, id: \.self) { Text("\($0) h").tag($0) }
                }
                .disabled(!showSparkline)
                Toggle("Only show a coloured dot when in range", isOn: $dotWhenInRange)
            }
            .tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }

            Form {
                Toggle("Enable alerts", isOn: $alertsEnabled)
                Group {
                    glucoseStepper("Low alert at or below", $alertLow, 40...150)
                    glucoseStepper("High alert at or above", $alertHigh, 150...400)
                    Toggle("Alert when dropping fast below \(store.format(100))", isOn: $alertFastDrop)
                    Stepper("No-data alert after \(staleMinutes) min", value: $staleMinutes, in: 10...60, step: 5)
                }
                .disabled(!alertsEnabled)
                Button("Send test notification") { store.alerts.sendTest() }
            }
            .tabItem { Label("Alerts", systemImage: "bell") }

            Form {
                Toggle("Share web page on local network", isOn: $shareOnLAN)
                    .onChange(of: shareOnLAN) { _, on in ServerConfig.setLAN(on) }
                Text(shareOnLAN
                     ? "Anyone on your Wi-Fi can open http://\(ProcessInfo.processInfo.hostName):8765 and see your glucose."
                     : "The web page is only reachable on this Mac: http://localhost:8765")
                    .font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button("Open web page") { store.openWebPage() }
                Button("Export all readings as CSV…") { store.exportCSV() }
            }
            .tabItem { Label("Server", systemImage: "server.rack") }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 300)
    }

    private func glucoseStepper(_ label: String, _ value: Binding<Int>, _ range: ClosedRange<Int>) -> some View {
        Stepper(value: value, in: range, step: useMmol ? 9 : 5) {
            HStack {
                Text(label)
                Spacer()
                Text("\(store.format(value.wrappedValue)) \(useMmol ? "mmol/L" : "mg/dL")").monospacedDigit()
            }
        }
    }
}

/// Reads and writes the server's config.json, restarting the launchd agent on change.
enum ServerConfig {
    static let url = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/freestyle-bar/config.json")

    static var lan: Bool {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return json["lan"] as? Bool ?? false
    }

    static func setLAN(_ on: Bool) {
        guard let data = try? Data(contentsOf: url),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        json["lan"] = on
        guard let out = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? out.write(to: url)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["kickstart", "-k", "gui/\(getuid())/co.dnk.freestyle-bar.server"]
        try? task.run()
    }
}
