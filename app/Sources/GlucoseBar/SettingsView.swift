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
    @AppStorage("alertPredictedLow") private var alertPredictedLow = true
    @AppStorage("staleMinutes") private var staleMinutes = 20
    @AppStorage("sensorDays") private var sensorDays = 14
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var shareOnLAN = ServerConfig.lan
    @AppStorage("serverURL") private var serverURL = ""

    @AppStorage("doseTarget") private var doseTarget = 120
    @State private var learned: DoseSuggestion?
    @State private var learnedError: String?
    @State private var updateStatus: String?
    @State private var checkingUpdates = false

    var body: some View {
        TabView {
            Form {
                Section {
                    Picker("Units", selection: $useMmol) {
                        Text("mg/dL").tag(false)
                        Text("mmol/L").tag(true)
                    }
                    glucoseStepper("Target low", $targetLow, 50...targetHigh - 10)
                    glucoseStepper("Target high", $targetHigh, targetLow + 10...300)
                } header: {
                    Text("Glucose")
                } footer: {
                    Text("Used for time in range, colours and meal scores.")
                }
                Section("Sensor") {
                    Picker("Sensor lifetime", selection: $sensorDays) {
                        Text("14 days").tag(14)
                        Text("15 days (Libre 3 Plus)").tag(15)
                    }
                }
                Section {
                    Toggle("Open at login", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, on in
                            try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                        }
                }
            }
            .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                Section {
                    Toggle("Show change since 5 min ago", isOn: $showDelta)
                    Toggle("Show trend line", isOn: $showSparkline)
                    Picker("Trend line covers", selection: $sparklineHours) {
                        ForEach(1...3, id: \.self) { Text("\($0) hour\($0 == 1 ? "" : "s")").tag($0) }
                    }
                    .disabled(!showSparkline)
                } header: {
                    Text("Menu Bar")
                }
                Section {
                    Toggle("Only show a coloured dot when in range", isOn: $dotWhenInRange)
                } footer: {
                    Text("The value comes back as soon as glucose leaves the target range.")
                }
            }
            .tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }

            Form {
                Section {
                    Toggle("Enable alerts", isOn: $alertsEnabled)
                }
                Section {
                    glucoseStepper("Low alert at or below", $alertLow, 40...150)
                    glucoseStepper("High alert at or above", $alertHigh, 150...400)
                    Toggle("Dropping fast below \(store.format(100))", isOn: $alertFastDrop)
                    Toggle("Heading low within 20 minutes", isOn: $alertPredictedLow)
                } header: {
                    Text("Glucose")
                } footer: {
                    Text("For 4 to 6 hours after moderate or hard exercise (2 hours more after 90 minutes or longer), heading-low and dropping-fast alerts come earlier.")
                }
                .disabled(!alertsEnabled)
                Section {
                    Stepper("No data for \(staleMinutes) minutes", value: $staleMinutes, in: 10...60, step: 5)
                } header: {
                    Text("Sensor")
                } footer: {
                    Text("Alerts repeat every 20 minutes while the condition lasts.")
                }
                .disabled(!alertsEnabled)
                Section {
                    Button("Send Test Notification") { store.alerts.sendTest() }
                }
            }
            .tabItem { Label("Alerts", systemImage: "bell.badge") }

            Form {
                Section {
                    glucoseStepper("Correct towards", $doseTarget, 80...180)
                } header: {
                    Text("Dose Suggestions")
                } footer: {
                    Text("Suggestions add or remove insulin to bring glucose to this level. They're estimates from your own logs, not medical advice.")
                }
                Section {
                    if let s = learned {
                        LabeledContent("Carb ratio", value: "1 u per \(formatUnits(s.carbRatio)) g")
                        ForEach(["morning", "midday", "evening"], id: \.self) { period in
                            if let p = s.byTime[period] {
                                LabeledContent("  \(period.capitalized)", value: "1 u per \(formatUnits(p.carbRatio)) g · \(p.meals) meal\(p.meals == 1 ? "" : "s")")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        LabeledContent("Correction", value: "1 u lowers about \(store.format(s.sensitivity)) \(useMmol ? "mmol/L" : "mg/dL")")
                        LabeledContent("Daily insulin", value: "\(formatUnits(s.dailyDose)) u on average")
                    } else if let learnedError {
                        Text(learnedError).foregroundStyle(.secondary)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                } header: {
                    Text("Learned from Your History")
                } footer: {
                    if let s = learned {
                        Text("From \(s.meals) meal\(s.meals == 1 ? "" : "s") and \(s.corrections) correction dose\(s.corrections == 1 ? "" : "s") over the last \(Int(s.days.rounded())) days, blended with the usual rules for your daily dose (1 u per \(formatUnits(s.rulesCarbRatio)) g, 1 u per \(store.format(s.rulesSensitivity))). The more you log, the more it follows your own data.")
                    }
                }
            }
            .tabItem { Label("Insulin", systemImage: "syringe") }
            .task {
                do { learned = try await store.doseSuggestion(carbs: 0) } catch { learnedError = error.localizedDescription }
            }

            Form {
                Section {
                    TextField("Server address", text: $serverURL, prompt: Text(GlucoseStore.localServer))
                        .onSubmit { Task { await store.refresh() } }
                } header: {
                    Text("Server")
                } footer: {
                    Text("Leave empty to use the server on this Mac, or enter another Mac's address, such as http://glucose-work.<tailnet>.ts.net:8765")
                }
                if !GlucoseStore.isRemote {
                    Section {
                        Toggle("Share web page on local network", isOn: $shareOnLAN)
                            .onChange(of: shareOnLAN) { _, on in ServerConfig.setLAN(on) }
                    } footer: {
                        Text(shareOnLAN
                             ? "Anyone on your Wi-Fi can open http://\(ProcessInfo.processInfo.hostName):8765 and see your glucose."
                             : "The web page is only reachable on this Mac: http://localhost:8765")
                            .textSelection(.enabled)
                    }
                }
                Section {
                    Button("Open Web Page") { store.openWebPage() }
                    Button("Export All Readings as CSV…") { store.exportCSV() }
                }
                Section {
                    LabeledContent("Version") {
                        HStack {
                            Text(Updater.version)
                            Button("Check for Updates") { Task { await checkForUpdates() } }
                                .disabled(Updater.isDev || checkingUpdates)
                        }
                    }
                } footer: {
                    Text(updateStatus ?? (Updater.isDev
                        ? "Built from a checkout, so it doesn't update. Run ./install.sh to switch to releases."
                        : "New releases install when GlucoseBar opens and every 6 hours."))
                }
            }
            .tabItem { Label("Server", systemImage: "server.rack") }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 460)
        .activatesWindow("settings")
    }

    private func checkForUpdates() async {
        checkingUpdates = true
        defer { checkingUpdates = false }
        updateStatus = "Checking…"
        guard let latest = await Updater.latest() else {
            updateStatus = "Couldn't reach GitHub. Try again later."
            return
        }
        if latest == Updater.version {
            updateStatus = "Up to date."
        } else if Updater.run() {
            updateStatus = "Installing \(latest)… GlucoseBar will quit and reopen."
        } else {
            updateStatus = "The updater isn't installed. Run the install command again."
        }
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
