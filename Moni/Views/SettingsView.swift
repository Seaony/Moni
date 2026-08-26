import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general, menuBar, alerts, aiUsage, modules, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .menuBar: "Menu Bar"
        case .alerts: "Alerts"
        case .aiUsage: "AI Usage"
        case .modules: "Modules"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .menuBar: "menubar.rectangle"
        case .alerts: "bell"
        case .aiUsage: "sparkles"
        case .modules: "square.grid.2x2"
        case .about: "info.circle"
        }
    }
}

struct SettingsView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var section: SettingsSection = .general

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("SETTINGS")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.7)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 4)

                ForEach(SettingsSection.allCases) { item in
                    Button {
                        select(item)
                    } label: {
                        Label(item.title, systemImage: item.symbol)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .foregroundStyle(section == item ? .white : .primary)
                            .background(section == item ? Color.accentColor : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    .buttonStyle(MoniPressButtonStyle())
                }
                Spacer()
            }
            .frame(width: 150)

            Group {
                switch section {
                case .general: GeneralSettings()
                case .menuBar: MenuBarSettings()
                case .alerts: AlertSettings()
                case .aiUsage: AIUsageSettings()
                case .modules: ModuleSettings()
                case .about: AboutSettings()
                }
            }
            .id(section)
            .transition(reduceMotion ? .identity : MoniMotion.pageTransition)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private func select(_ newSection: SettingsSection) {
        guard newSection != section else { return }
        if reduceMotion {
            section = newSection
        } else {
            withAnimation(MoniMotion.navigation) {
                section = newSection
            }
        }
    }
}

private struct AIUsageSettings: View {
    @EnvironmentObject private var store: AIUsageStore
    @AppStorage(PreferenceKey.aiUsageRangeDays) private var rangeDays = 30

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 12) {
                DetailPanel("Usage range") {
                    Picker("History", selection: $rangeDays) {
                        Text("7 days").tag(7)
                        Text("30 days").tag(30)
                        Text("90 days").tag(90)
                    }
                    .pickerStyle(.segmented)
                    Text("Moni reads usage metadata from local session logs. Prompt and response text is never shown.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                DetailPanel("Detected providers") {
                    providerStatus("Codex", detected: store.summary.providers.contains { $0.provider == "Codex" })
                    providerStatus("Claude", detected: store.summary.providers.contains { $0.provider == "Claude" })
                    HStack {
                        Text("Costs are local estimates using public API rates, not subscription invoices or quota usage.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if store.isLoading {
                            ProgressView()
                                .controlSize(.small)
                                .transition(MoniMotion.itemTransition)
                        }
                        Button("Rescan") { store.refresh(days: rangeDays) }
                            .disabled(store.isLoading)
                    }
                }
            }
        }
        .onChange(of: rangeDays) { _, value in
            store.refresh(days: value)
        }
        .task {
            store.loadIfNeeded(days: rangeDays)
        }
        .moniAnimation(value: store.isLoading)
    }

    private func providerStatus(_ name: String, detected: Bool) -> some View {
        HStack {
            Label(name, systemImage: name == "Codex" ? "terminal" : "brain")
            Spacer()
            Label(detected ? "Detected" : "Not detected", systemImage: detected ? "checkmark.circle.fill" : "minus.circle")
                .foregroundStyle(detected ? .green : .secondary)
        }
    }
}

private struct AlertSettings: View {
    @AppStorage(PreferenceKey.cpuAlertEnabled) private var cpuEnabled = false
    @AppStorage(PreferenceKey.cpuAlertThreshold) private var cpuThreshold = 85.0
    @AppStorage(PreferenceKey.memoryAlertEnabled) private var memoryEnabled = false
    @AppStorage(PreferenceKey.memoryAlertThreshold) private var memoryThreshold = 90.0
    @AppStorage(PreferenceKey.diskAlertEnabled) private var diskEnabled = false
    @AppStorage(PreferenceKey.diskAlertThreshold) private var diskThreshold = 90.0
    @AppStorage(PreferenceKey.notificationAlerts) private var notificationAlerts = false
    @AppStorage(PreferenceKey.alertSounds) private var alertSounds = true
    @AppStorage(PreferenceKey.repeatAlerts) private var repeatAlerts = false
    @State private var notificationError: String?

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 12) {
                DetailPanel("Thresholds") {
                    thresholdRow("CPU usage", enabled: $cpuEnabled, value: $cpuThreshold)
                    Divider()
                    thresholdRow("Memory usage", enabled: $memoryEnabled, value: $memoryThreshold)
                    Divider()
                    thresholdRow("System disk usage", enabled: $diskEnabled, value: $diskThreshold)
                    Text("Temperature alerts are unavailable because macOS does not expose sensor values through a public API.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                DetailPanel("Delivery") {
                    Toggle("Show system notifications", isOn: Binding(
                        get: { notificationAlerts },
                        set: updateNotifications
                    ))
                    Toggle("Play alert sound", isOn: $alertSounds)
                        .disabled(!notificationAlerts)
                    Toggle("Repeat every 5 minutes while above threshold", isOn: $repeatAlerts)
                    if let notificationError {
                        Text(notificationError)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .transition(MoniMotion.itemTransition)
                    }
                }
            }
        }
        .moniAnimation(value: notificationError)
    }

    private func thresholdRow(_ title: String, enabled: Binding<Bool>, value: Binding<Double>) -> some View {
        HStack {
            Toggle(title, isOn: enabled)
            Spacer()
            Stepper(value: value, in: 50...99, step: 1) {
                Text("\(Int(value.wrappedValue))%")
                    .monospacedDigit()
                    .frame(width: 42, alignment: .trailing)
                    .moniNumericTransition(value.wrappedValue)
            }
            .disabled(!enabled.wrappedValue)
        }
    }

    private func updateNotifications(_ isEnabled: Bool) {
        guard isEnabled else {
            notificationAlerts = false
            notificationError = nil
            return
        }

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            Task { @MainActor in
                notificationAlerts = granted
                notificationError = error?.localizedDescription ?? (granted ? nil : "Notification permission was not granted.")
            }
        }
    }
}

private struct GeneralSettings: View {
    @AppStorage(PreferenceKey.appearance) private var appearance = AppAppearance.system.rawValue
    @AppStorage(PreferenceKey.samplingInterval) private var samplingInterval = 1.0
    @AppStorage(PreferenceKey.showDockIcon) private var showDockIcon = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemError: String?

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 12) {
                DetailPanel("Appearance") {
                    Picker("Appearance", selection: $appearance) {
                        ForEach(AppAppearance.allCases) { option in
                            Text(option.title).tag(option.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                DetailPanel("Sampling") {
                    HStack {
                        Text("Update interval")
                        Spacer()
                        Picker("Update interval", selection: $samplingInterval) {
                            Text("0.3 s").tag(0.3)
                            Text("0.7 s").tag(0.7)
                            Text("1 s").tag(1.0)
                            Text("2 s").tag(2.0)
                            Text("5 s").tag(5.0)
                        }
                        .labelsHidden()
                        .frame(width: 130)
                    }
                    Text("Shorter intervals use more processor time.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                DetailPanel("Behavior") {
                    Toggle("Launch Moni at login", isOn: Binding(
                        get: { launchAtLogin },
                        set: updateLoginItem
                    ))
                    Toggle("Show Moni in the Dock", isOn: $showDockIcon)
                    if let loginItemError {
                        Text(loginItemError)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .transition(MoniMotion.itemTransition)
                    }
                }
            }
        }
        .moniAnimation(value: loginItemError)
    }

    private func updateLoginItem(_ isEnabled: Bool) {
        do {
            if isEnabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = isEnabled
            loginItemError = nil
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            loginItemError = error.localizedDescription
        }
    }
}

private struct MenuBarSettings: View {
    @EnvironmentObject private var monitor: SystemMonitor
    @AppStorage(PreferenceKey.compactMenuBar) private var compactMenuBar = false
    @AppStorage(PreferenceKey.menuBarMetric) private var metric = MenuBarMetric.cpu.rawValue

    var body: some View {
        VStack(spacing: 12) {
            DetailPanel("Preview") {
                HStack {
                    Spacer()
                    HStack(spacing: 5) {
                        if !compactMenuBar {
                            Image(systemName: selectedMetric.symbol)
                                .transition(MoniMotion.itemTransition)
                        }
                        Text(previewValue)
                            .monospacedDigit()
                            .moniNumericTransition(previewValue)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color.primary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .moniAnimation(value: compactMenuBar)
                    Spacer()
                }
            }

            DetailPanel("Content") {
                Picker("Metric", selection: $metric) {
                    ForEach(MenuBarMetric.allCases) { item in
                        Label(item.title, systemImage: item.symbol).tag(item.rawValue)
                    }
                }
                Toggle("Compact value only", isOn: $compactMenuBar)
            }
            Spacer()
        }
    }

    private var selectedMetric: MenuBarMetric {
        MenuBarMetric(rawValue: metric) ?? .cpu
    }

    private var previewValue: String {
        switch selectedMetric {
        case .cpu: "\(Int(monitor.snapshot.cpu.total.rounded()))%"
        case .memory: "\(Int(monitor.snapshot.memory.usedPercent.rounded()))%"
        case .network: "↓\(ByteCountFormatter.string(fromByteCount: Int64(max(0, monitor.snapshot.network.downloadBytesPerSecond)), countStyle: .decimal))/s"
        case .disk: "\(Int((monitor.snapshot.volumes.first { $0.mountPath == "/" }?.usedPercent ?? 0).rounded()))%"
        case .battery: monitor.snapshot.power.batteryPercent.map { "\(Int($0.rounded()))%" } ?? "—"
        }
    }
}

private struct ModuleSettings: View {
    @AppStorage(PreferenceKey.showHost) private var showHost = true
    @AppStorage(PreferenceKey.showCPU) private var showCPU = true
    @AppStorage(PreferenceKey.showMemory) private var showMemory = true
    @AppStorage(PreferenceKey.showGPU) private var showGPU = true
    @AppStorage(PreferenceKey.showNetwork) private var showNetwork = true
    @AppStorage(PreferenceKey.showStorage) private var showStorage = true
    @AppStorage(PreferenceKey.showProcesses) private var showProcesses = true
    @AppStorage(PreferenceKey.showPower) private var showPower = true
    @AppStorage(PreferenceKey.showDocker) private var showDocker = true

    var body: some View {
        DetailPanel("Summary cards") {
            moduleToggle("Host", "server.rack", $showHost)
            moduleToggle("CPU", "cpu", $showCPU)
            moduleToggle("Memory", "memorychip", $showMemory)
            moduleToggle("GPU", "display", $showGPU)
            moduleToggle("Network", "arrow.up.arrow.down", $showNetwork)
            moduleToggle("Storage", "internaldrive", $showStorage)
            moduleToggle("Processes", "list.bullet.rectangle", $showProcesses)
            moduleToggle("Power & Sensors", "battery.75percent", $showPower)
            moduleToggle("Docker", "shippingbox", $showDocker)
            Label("AI Usage is always shown", systemImage: "sparkles")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func moduleToggle(_ title: String, _ symbol: String, _ binding: Binding<Bool>) -> some View {
        Toggle(isOn: binding) {
            Label(title, systemImage: symbol)
        }
    }
}

private struct AboutSettings: View {
    @EnvironmentObject private var updates: UpdateController

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    var body: some View {
        VStack(spacing: 12) {
            DetailPanel("Moni") {
                HStack(spacing: 14) {
                    Image(systemName: "chart.bar.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(.cyan)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Moni")
                            .font(.title2.bold())
                        Text("Version \(version) (\(build))")
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Native system monitoring for macOS.")
                    .foregroundStyle(.secondary)
            }

            DetailPanel("Application") {
                Button("Check for Updates…") {
                    updates.checkForUpdates()
                }
                .disabled(!updates.canCheckForUpdates)

                Toggle(
                    "Check for updates automatically",
                    isOn: Binding(
                        get: { updates.automaticallyChecksForUpdates },
                        set: updates.setAutomaticallyChecksForUpdates
                    )
                )
                .disabled(updates.configurationError != nil)

                Toggle(
                    "Download and install updates automatically",
                    isOn: Binding(
                        get: { updates.automaticallyDownloadsUpdates },
                        set: updates.setAutomaticallyDownloadsUpdates
                    )
                )
                .disabled(!updates.allowsAutomaticUpdates)

                if let configurationError = updates.configurationError {
                    Text(configurationError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()
                Button("Quit Moni") {
                    NSApp.terminate(nil)
                }
            }
            Spacer()
        }
    }
}
