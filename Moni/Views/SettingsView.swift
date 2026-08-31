import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications
import WidgetKit

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, menuBar, alerts, modules, cleanup, about

    var id: String { rawValue }

    var title: String {
        let key: String = switch self {
        case .general: "General"
        case .menuBar: "Menu Bar"
        case .alerts: "Alerts"
        case .modules: "Modules"
        case .cleanup: "Cleanup"
        case .about: "About"
        }
        return MoniLocalization.string(key)
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .menuBar: "menubar.rectangle"
        case .alerts: "bell"
        case .modules: "square.grid.2x2"
        case .cleanup: "shield.checkered"
        case .about: "info.circle"
        }
    }
}

struct SettingsView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var section: SettingsSection
    @AppStorage(PreferenceKey.samplingInterval) private var samplingInterval = 0.7

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsSection.allCases) { item in
                    Button {
                        select(item)
                    } label: {
                        Text(item.title)
                            .font(.system(size: 13, weight: .semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .foregroundStyle(section == item ? MoniPalette.foreground : MoniPalette.foregroundTertiary)
                            .background(section == item ? MoniPalette.control : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(MoniPressButtonStyle())
                }
                Spacer()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Moni \(appVersion)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(MoniPalette.foregroundTertiary)
                    Text("Sampling \(samplingLabel)")
                        .font(.system(size: 12))
                        .foregroundStyle(MoniPalette.foregroundSecondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(MoniPalette.insetSecondary)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .frame(width: 186)

            Group {
                switch section {
                case .general: GeneralSettings()
                case .menuBar: MenuBarSettings()
                case .alerts: AlertSettings()
                case .modules: ModuleSettings()
                case .cleanup: CleanupSettings()
                case .about: AboutSettings()
                }
            }
            .id(section)
            .transition(reduceMotion ? .identity : MoniMotion.pageTransition)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private var samplingLabel: String {
        samplingInterval == 1 ? "1 s" : String(format: "%.1f s", samplingInterval)
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

private struct SettingsChoiceButton: View {
    let title: String
    let selected: Bool
    var systemImage: String?
    var expand = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(MoniLocalization.string(title))
            }
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(selected ? Color.white : MoniPalette.foregroundSecondary)
                .frame(maxWidth: expand ? .infinity : nil)
                .padding(.horizontal, 13)
                .padding(.vertical, 7)
                .background(selected ? MoniPalette.blue : MoniPalette.control)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(MoniPressButtonStyle())
    }
}

private struct SettingsToggleRow: View {
    let title: String
    let hint: String
    let isOn: Bool
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(MoniLocalization.string(title))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(MoniPalette.foreground)
                    Text(MoniLocalization.string(hint))
                        .font(.system(size: 12))
                        .foregroundStyle(MoniPalette.foregroundTertiary)
                }
                Spacer(minLength: 12)
                SettingsSwitch(isOn: isOn)
            }
            .padding(.vertical, 9)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .moniPointingHand()
        .moniAnimation(value: isOn)
    }
}

private struct SettingsSwitch: View {
    let isOn: Bool

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? MoniPalette.green : MoniPalette.controlSelected)
                .frame(width: 40, height: 24)
            Circle()
                .fill(.white)
                .frame(width: 20, height: 20)
                .padding(2)
        }
    }
}

private struct AlertSettings: View {
    @AppStorage(PreferenceKey.cpuAlertThreshold) private var cpuThreshold = 85.0
    @AppStorage(PreferenceKey.memoryAlertThreshold) private var memoryThreshold = 90.0
    @AppStorage(PreferenceKey.diskAlertThreshold) private var diskThreshold = 90.0
    @AppStorage(PreferenceKey.temperatureAlertThreshold) private var temperatureThreshold = 80.0
    @AppStorage(PreferenceKey.notificationAlerts) private var notificationAlerts = false
    @AppStorage(PreferenceKey.alertSounds) private var alertSounds = true
    @AppStorage(PreferenceKey.repeatAlerts) private var repeatAlerts = false
    @State private var notificationError: String?

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 12) {
                DetailPanel("Thresholds") {
                    if !notificationAlerts {
                        Text("Turn on the notification banner below for these limits to alert you.")
                            .font(.system(size: 12))
                            .foregroundStyle(MoniPalette.foregroundTertiary)
                    }
                    VStack(spacing: 18) {
                        thresholdRow("CPU load", hint: "sustained over 30s", color: MoniPalette.pink, value: $cpuThreshold)
                        thresholdRow("Memory used", hint: "physical memory", color: MoniPalette.blue, value: $memoryThreshold)
                        thresholdRow("CPU temperature", hint: "die sensor", unit: "°C", color: MoniPalette.orange, value: $temperatureThreshold)
                        thresholdRow("Disk space used", hint: "boot volume", color: MoniPalette.yellow, value: $diskThreshold)
                    }
                }

                DetailPanel("Delivery") {
                    VStack(spacing: 2) {
                        SettingsToggleRow(
                            title: "Notification banner",
                            hint: "Show a macOS notification",
                            isOn: notificationAlerts
                        ) {
                            updateNotifications(!notificationAlerts)
                        }
                        SettingsToggleRow(
                            title: "Play sound",
                            hint: "Alert tone when a limit is crossed",
                            isOn: alertSounds,
                            isEnabled: notificationAlerts
                        ) {
                            alertSounds.toggle()
                        }
                        SettingsToggleRow(
                            title: "Repeat every 5 min",
                            hint: "Keep alerting while over the limit",
                            isOn: repeatAlerts,
                            isEnabled: notificationAlerts
                        ) {
                            repeatAlerts.toggle()
                        }
                    }
                    if let notificationError {
                        Text(notificationError)
                            .font(.system(size: 12))
                            .foregroundStyle(MoniPalette.red)
                            .padding(.horizontal, 10)
                            .transition(MoniMotion.itemTransition)
                    }
                }
            }
        }
        .moniAnimation(value: notificationError)
    }

    private func thresholdRow(
        _ title: String,
        hint: String,
        unit: String = "%",
        color: Color,
        value: Binding<Double>
    ) -> some View {
        VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(MoniLocalization.string(title))
                    .font(.system(size: 13, weight: .semibold))
                Text(MoniLocalization.string(hint))
                    .font(.system(size: 12))
                    .foregroundStyle(MoniPalette.foregroundTertiary)
                Spacer()
                Text("\(Int(value.wrappedValue))\(unit)")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(color)
                    .monospacedDigit()
                    .moniNumericTransition(value.wrappedValue)
            }

            HStack(spacing: 10) {
                thresholdButton("−") {
                    value.wrappedValue = max(20, value.wrappedValue - 5)
                }
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(MoniPalette.track)
                        Capsule()
                            .fill(color)
                            .frame(width: proxy.size.width * value.wrappedValue / 100)
                    }
                    // The grab area is an overlay so widening it cannot squeeze the
                    // 6pt bar the GeometryReader is sized to.
                    .overlay {
                        Color.clear
                            .frame(height: 22)
                            .contentShape(Rectangle())
                            .pointerStyle(.columnResize)
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { drag in
                                        let fraction = min(max(drag.location.x / max(1, proxy.size.width), 0), 1)
                                        let steps = (fraction * 100 / 5).rounded()
                                        value.wrappedValue = min(100, max(20, steps * 5))
                                    }
                            )
                    }
                }
                .frame(height: 6)
                thresholdButton("+") {
                    value.wrappedValue = min(100, value.wrappedValue + 5)
                }
            }
        }
    }

    private func thresholdButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 15))
                .frame(width: 26, height: 26)
                .background(MoniPalette.control)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(MoniPressButtonStyle())
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
                notificationError = error?.localizedDescription
                    ?? (granted ? nil : "Notification permission was not granted.")
            }
        }
    }
}

private struct GeneralSettings: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(PreferenceKey.appLanguage) private var appLanguage = AppLanguage.english.rawValue
    @AppStorage(PreferenceKey.appearance) private var appearance = AppAppearance.system.rawValue
    @AppStorage(PreferenceKey.samplingInterval) private var samplingInterval = 0.7
    @AppStorage(PreferenceKey.windowZoom) private var windowZoom = 1.0
    @AppStorage(PreferenceKey.notificationAlerts) private var notificationAlerts = false
    @AppStorage(PreferenceKey.showDockIcon) private var showDockIcon = false
    @AppStorage(PreferenceKey.compactMenuBar) private var compactMenuBar = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemError: String?
    @State private var notificationError: String?
    @State private var pendingWindowZoom: Double?

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 12) {
                DetailPanel("Language") {
                    HStack(spacing: 6) {
                        ForEach(AppLanguage.allCases) { language in
                            SettingsChoiceButton(
                                title: language.title,
                                selected: selectedLanguage == language,
                                systemImage: language == .english ? "character.book.closed" : "character.book.closed.zh",
                                expand: true
                            ) {
                                appLanguage = language.rawValue
                                MoniLocalization.setLanguage(language)
                                WidgetCenter.shared.reloadAllTimelines()
                            }
                        }
                    }
                    Text("Changes the language across Moni, the menu bar, notifications, and widgets.")
                        .font(.system(size: 12))
                        .foregroundStyle(MoniPalette.foregroundTertiary)
                }

                DetailPanel("Appearance") {
                    HStack(spacing: 6) {
                        SettingsChoiceButton(
                            title: "System",
                            selected: storedAppearance == .system,
                            systemImage: "circle.lefthalf.filled",
                            expand: true
                        ) {
                            appearance = AppAppearance.system.rawValue
                        }
                        SettingsChoiceButton(
                            title: "Dark",
                            selected: storedAppearance == .dark,
                            systemImage: "moon.fill",
                            expand: true
                        ) {
                            appearance = AppAppearance.dark.rawValue
                        }
                        SettingsChoiceButton(
                            title: "Light",
                            selected: storedAppearance == .light,
                            systemImage: "sun.max.fill",
                            expand: true
                        ) {
                            appearance = AppAppearance.light.rawValue
                        }
                    }
                    Text(
                        storedAppearance == .system
                            ? MoniLocalization.format(
                                "System follows the macOS appearance, currently %@.",
                                MoniLocalization.string(colorScheme == .dark ? "dark" : "light")
                            )
                            : MoniLocalization.string("Light mode follows the same palette with inverted surfaces.")
                    )
                    .font(.system(size: 12))
                    .foregroundStyle(MoniPalette.foregroundTertiary)
                }

                DetailPanel("Sampling interval") {
                    HStack(spacing: 6) {
                        ForEach([0.3, 0.7, 1.0, 2.0, 5.0], id: \.self) { interval in
                            SettingsChoiceButton(
                                title: interval == 1 ? "1s" : String(format: "%.1gs", interval),
                                selected: samplingInterval == interval
                            ) {
                                samplingInterval = interval
                            }
                        }
                    }
                    Text("Shorter intervals give smoother graphs and use slightly more CPU.")
                        .font(.system(size: 12))
                        .foregroundStyle(MoniPalette.foregroundTertiary)
                }

                DetailPanel("Zoom") {
                    HStack(spacing: 12) {
                        Text("0.5×")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(MoniPalette.foregroundTertiary)

                        Slider(
                            value: Binding(
                                get: { pendingWindowZoom ?? windowZoom },
                                set: { pendingWindowZoom = $0 }
                            ),
                            in: 0.5...1.5,
                            step: 0.1,
                            onEditingChanged: { isEditing in
                                guard !isEditing, let pendingWindowZoom else { return }
                                windowZoom = pendingWindowZoom
                                self.pendingWindowZoom = nil
                            }
                        )

                        Text(String(format: "%.1f×", pendingWindowZoom ?? windowZoom))
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .frame(width: 38, alignment: .trailing)

                        Button("Reset") {
                            pendingWindowZoom = nil
                            windowZoom = 1.0
                        }
                        .buttonStyle(MoniPressButtonStyle())
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle((pendingWindowZoom ?? windowZoom) == 1.0 ? MoniPalette.foregroundTertiary : MoniPalette.blue)
                        .disabled((pendingWindowZoom ?? windowZoom) == 1.0)
                    }
                    Text("Scales the entire pop-up window. The default size is 1.0×.")
                        .font(.system(size: 12))
                        .foregroundStyle(MoniPalette.foregroundTertiary)
                }

                DetailPanel("Behavior") {
                    VStack(spacing: 2) {
                        SettingsToggleRow(
                            title: "Launch at login",
                            hint: "Start Moni when you log in",
                            isOn: launchAtLogin
                        ) {
                            updateLoginItem(!launchAtLogin)
                        }
                        SettingsToggleRow(
                            title: "Threshold alerts",
                            hint: "Notify when a limit below is crossed",
                            isOn: notificationAlerts
                        ) {
                            updateNotifications(!notificationAlerts)
                        }
                        SettingsToggleRow(
                            title: "Show Dock icon",
                            hint: "Off keeps Moni menu-bar only",
                            isOn: showDockIcon
                        ) {
                            showDockIcon.toggle()
                            NSApp.setActivationPolicy(showDockIcon ? .regular : .accessory)
                        }
                        SettingsToggleRow(
                            title: "Compact menu bar",
                            hint: "Show only the first selected item",
                            isOn: compactMenuBar
                        ) {
                            compactMenuBar.toggle()
                        }
                    }
                    if let loginItemError {
                        settingsError(loginItemError)
                    }
                    if let notificationError {
                        settingsError(notificationError)
                    }
                }
            }
        }
        .moniAnimation(value: loginItemError)
        .moniAnimation(value: notificationError)
    }

    private var storedAppearance: AppAppearance {
        AppAppearance(rawValue: appearance) ?? .system
    }

    private var selectedLanguage: AppLanguage {
        AppLanguage(rawValue: appLanguage) ?? .english
    }

    private func settingsError(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 12))
            .foregroundStyle(MoniPalette.red)
            .padding(.horizontal, 10)
            .transition(MoniMotion.itemTransition)
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

    private func updateNotifications(_ isEnabled: Bool) {
        guard isEnabled else {
            notificationAlerts = false
            notificationError = nil
            return
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            Task { @MainActor in
                notificationAlerts = granted
                notificationError = error?.localizedDescription
                    ?? (granted ? nil : "Notification permission was not granted.")
            }
        }
    }
}

private struct MenuBarSettings: View {
    @EnvironmentObject private var monitor: SystemMonitor
    @AppStorage(PreferenceKey.compactMenuBar) private var compactMenuBar = false
    @AppStorage(PreferenceKey.menuBarMetric) private var metric = MenuBarMetric.cpu.rawValue
    @AppStorage(PreferenceKey.menuBarItems) private var itemValue = "cpu,memory"
    @AppStorage(PreferenceKey.menuBarDisplayStyle) private var styleValue = MenuBarDisplayStyle.valueOnly.rawValue

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 12) {
                DetailPanel("Preview") {
                    HStack(spacing: 14) {
                        Spacer()
                        ForEach(previewMetrics) { item in
                            HStack(spacing: 5) {
                                if displayStyle != .valueOnly {
                                    MenuBarMiniGraph(
                                        values: previewHistory(item),
                                        color: metricColor(item)
                                    )
                                }
                                if displayStyle != .graphOnly {
                                    if displayStyle == .valueOnly {
                                        Text(previewTag(item))
                                            .font(.system(size: 11, weight: .bold))
                                            .foregroundStyle(metricColor(item))
                                    }
                                    Text(previewValue(item))
                                        .font(.system(size: 12, weight: .semibold))
                                        .monospacedDigit()
                                }
                            }
                        }
                        Text(Date.now.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                            .font(.system(size: 12))
                            .foregroundStyle(MoniPalette.foregroundTertiary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(MoniPalette.inset)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                DetailPanel("Items in menu bar") {
                    HStack(spacing: 6) {
                        ForEach(MenuBarMetric.allCases) { item in
                            Button {
                                toggle(item)
                            } label: {
                                Text(item.title)
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(
                                        selectedMetrics.contains(item)
                                            ? MoniPalette.blue
                                            : MoniPalette.foregroundSecondary
                                    )
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(
                                        selectedMetrics.contains(item)
                                            ? MoniPalette.blue.opacity(0.2)
                                            : MoniPalette.control
                                    )
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                                            .stroke(
                                                selectedMetrics.contains(item)
                                                    ? MoniPalette.blue.opacity(0.45)
                                                    : MoniPalette.line,
                                                lineWidth: 1
                                            )
                                    }
                                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            }
                            .buttonStyle(MoniPressButtonStyle())
                        }
                    }

                    Text("DISPLAY STYLE")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(MoniPalette.foregroundSecondary)
                        .tracking(0.7)
                        .padding(.top, 10)

                    HStack(spacing: 6) {
                        ForEach(MenuBarDisplayStyle.allCases) { style in
                            SettingsChoiceButton(title: style.title, selected: displayStyle == style) {
                                styleValue = style.rawValue
                            }
                        }
                    }
                }
            }
        }
    }

    private var selectedMetrics: [MenuBarMetric] {
        let selected = Set(itemValue.split(separator: ",").map(String.init))
        let values = MenuBarMetric.allCases.filter { selected.contains($0.rawValue) }
        return values.isEmpty ? [.cpu] : values
    }

    private var displayStyle: MenuBarDisplayStyle {
        MenuBarDisplayStyle(rawValue: styleValue) ?? .valueOnly
    }

    private var previewMetrics: [MenuBarMetric] {
        compactMenuBar ? Array(selectedMetrics.prefix(1)) : selectedMetrics
    }

    private func toggle(_ item: MenuBarMetric) {
        var values = selectedMetrics
        if let index = values.firstIndex(of: item) {
            guard values.count > 1 else { return }
            values.remove(at: index)
        } else {
            values.append(item)
        }
        itemValue = MenuBarMetric.allCases
            .filter(values.contains)
            .map(\.rawValue)
            .joined(separator: ",")
        metric = values.first?.rawValue ?? MenuBarMetric.cpu.rawValue
    }

    private func previewTag(_ item: MenuBarMetric) -> String {
        switch item {
        case .temperature: "TMP"
        default: String(item.title.prefix(3)).uppercased()
        }
    }

    private func previewValue(_ item: MenuBarMetric) -> String {
        switch item {
        case .cpu: "\(Int(monitor.snapshot.cpu.total.rounded()))%"
        case .memory: "\(Int(monitor.snapshot.memory.usedPercent.rounded()))%"
        case .network:
            ByteCountFormatter.string(
                fromByteCount: Int64(max(0, monitor.snapshot.network.downloadBytesPerSecond)),
                countStyle: .decimal
            )
        case .disk: "\(Int((monitor.snapshot.volumes.first { $0.mountPath == "/" }?.usedPercent ?? 0).rounded()))%"
        case .battery: monitor.snapshot.power.batteryPercent.map { "\(Int($0.rounded()))%" } ?? "—"
        case .temperature:
            monitor.snapshot.power.cpuTemperatureCelsius.map { "\(Int($0.rounded()))°" } ?? "—"
        }
    }

    private func previewHistory(_ item: MenuBarMetric) -> [Double] {
        switch item {
        case .cpu: monitor.cpuHistory
        case .memory: monitor.memoryHistory
        case .network: monitor.downloadHistory
        case .disk: monitor.diskReadHistory
        case .battery: monitor.batteryHistory
        case .temperature: monitor.cpuTemperatureHistory
        }
    }

    private func metricColor(_ item: MenuBarMetric) -> Color {
        switch item {
        case .cpu: MoniPalette.pink
        case .memory: MoniPalette.blue
        case .network: MoniPalette.cyan
        case .disk, .temperature: MoniPalette.orange
        case .battery: MoniPalette.green
        }
    }
}

private struct ModuleSettings: View {
    @EnvironmentObject private var monitor: SystemMonitor
    @AppStorage(PreferenceKey.showHost) private var showHost = true
    @AppStorage(PreferenceKey.showCPU) private var showCPU = true
    @AppStorage(PreferenceKey.showMemory) private var showMemory = true
    @AppStorage(PreferenceKey.showGPU) private var showGPU = true
    @AppStorage(PreferenceKey.showNetwork) private var showNetwork = true
    @AppStorage(PreferenceKey.showStorage) private var showStorage = true
    @AppStorage(PreferenceKey.showProcesses) private var showProcesses = true
    @AppStorage(PreferenceKey.showPower) private var showPower = true
    @AppStorage(PreferenceKey.showDocker) private var showDocker = true
    @AppStorage(PreferenceKey.summaryGridDensity) private var gridDensityValue = SummaryGridDensity.comfortable.rawValue

    private var snapshot: SystemSnapshot { monitor.snapshot }

    private var gridDensity: SummaryGridDensity {
        SummaryGridDensity(rawValue: gridDensityValue) ?? .comfortable
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 12) {
                DetailPanel("Summary cards") {
                    VStack(spacing: 2) {
                        moduleRow("Host", color: MoniPalette.blue, note: "uptime, load", isOn: $showHost)
                        moduleRow(
                            "CPU",
                            color: MoniPalette.pink,
                            note: "\(ProcessInfo.processInfo.processorCount) cores",
                            isOn: $showCPU
                        )
                        moduleRow(
                            "Memory",
                            color: MoniPalette.blue,
                            note: memoryCapacity,
                            isOn: $showMemory
                        )
                        moduleRow(
                            "GPU",
                            color: MoniPalette.green,
                            note: count(snapshot.gpuDevices.count, singular: "device"),
                            isOn: $showGPU
                        )
                        moduleRow(
                            "Network",
                            color: MoniPalette.cyan,
                            note: count(snapshot.network.interfaces.count, singular: "interface"),
                            isOn: $showNetwork
                        )
                        moduleRow(
                            "Storage",
                            color: MoniPalette.orange,
                            note: count(snapshot.volumes.count, singular: "volume"),
                            isOn: $showStorage
                        )
                        moduleRow(
                            "Processes",
                            color: MoniPalette.purple,
                            note: snapshot.processes.count.formatted(),
                            isOn: $showProcesses
                        )
                        moduleRow(
                            "Sensors",
                            color: MoniPalette.yellow,
                            note: count(snapshot.power.temperatureSensors.count, singular: "probe"),
                            isOn: $showPower
                        )
                        moduleRow(
                            "Docker",
                            color: MoniPalette.blue,
                            note: snapshot.docker.isInstalled
                                ? snapshot.docker.statusTitle.lowercased()
                                : "unavailable",
                            isOn: $showDocker
                        )
                    }
                }

                DetailPanel("Grid density") {
                    HStack(spacing: 6) {
                        ForEach(SummaryGridDensity.allCases) { density in
                            Button {
                                gridDensityValue = density.rawValue
                            } label: {
                                Text(density.title)
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundStyle(gridDensity == density ? Color.white : MoniPalette.foregroundSecondary)
                                    .padding(.horizontal, 13)
                                    .padding(.vertical, 7)
                                    .background(gridDensity == density ? MoniPalette.blue : MoniPalette.control)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .moniPointingHand()
                        }
                    }
                }
            }
        }
    }

    private func moduleRow(
        _ title: String,
        color: Color,
        note: String,
        isOn: Binding<Bool>
    ) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(color)
                    .frame(width: 9, height: 9)
                Text(MoniLocalization.string(title))
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 12)
                Text(MoniLocalization.string(note))
                    .font(.system(size: 12))
                    .foregroundStyle(MoniPalette.foregroundTertiary)
                    .lineLimit(1)
                SettingsSwitch(isOn: isOn.wrappedValue)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .moniPointingHand()
        .moniAnimation(value: isOn.wrappedValue)
    }

    private var memoryCapacity: String {
        ByteCountFormatter.string(
            fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory),
            countStyle: .memory
        )
    }

    private func count(_ value: Int, singular: String) -> String {
        let unit = MoniLocalization.string(singular + (value == 1 ? "" : "s"))
        return MoniLocalization.format("%@ %@", value.formatted(), unit)
    }
}

private struct CleanupSettings: View {
    @State private var whitelist: [String] = []
    @State private var history: [CleanupOperationRecord] = []
    @State private var confirmsHistoryClear = false
    @State private var historyError: String?

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 12) {
                DetailPanel("Protected paths") {
                    Text("System-critical locations are always protected. Add personal paths here to exclude them and their contents from every cleanup operation.")
                        .font(.system(size: 12))
                        .foregroundStyle(MoniPalette.foregroundTertiary)

                    if whitelist.isEmpty {
                        Text("No custom protected paths")
                            .font(.system(size: 12.5))
                            .foregroundStyle(MoniPalette.foregroundTertiary)
                            .frame(maxWidth: .infinity, minHeight: 40, alignment: .center)
                    } else {
                        VStack(spacing: 2) {
                            ForEach(whitelist, id: \.self) { path in
                                HStack(spacing: 10) {
                                    Image(systemName: "shield.fill")
                                        .foregroundStyle(MoniPalette.green)
                                    Text(path)
                                        .font(.system(size: 12.5))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer(minLength: 8)
                                    Button {
                                        CleanupPreferences.removeFromWhitelist(path)
                                        reloadWhitelist()
                                    } label: {
                                        Image(systemName: "minus.circle")
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(MoniPalette.foregroundTertiary)
                                    .help(MoniLocalization.string("Remove protection"))
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(MoniPalette.inset)
                                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            }
                        }
                    }

                    Button {
                        chooseProtectedPaths()
                    } label: {
                        Label(MoniLocalization.string("Add protected path…"), systemImage: "plus")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(MoniPressButtonStyle())
                    .background(MoniPalette.control)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                DetailPanel("Operation history") {
                    HStack {
                        Text(MoniLocalization.format("Latest %@ operations", min(history.count, 30).formatted()))
                            .font(.system(size: 12))
                            .foregroundStyle(MoniPalette.foregroundTertiary)
                        Spacer()
                        Button(MoniLocalization.string("Clear")) {
                            confirmsHistoryClear = true
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(history.isEmpty ? MoniPalette.foregroundTertiary : MoniPalette.red)
                        .disabled(history.isEmpty)
                    }

                    if history.isEmpty {
                        Text("No cleanup operations recorded")
                            .font(.system(size: 12.5))
                            .foregroundStyle(MoniPalette.foregroundTertiary)
                            .frame(maxWidth: .infinity, minHeight: 52, alignment: .center)
                    } else {
                        VStack(spacing: 2) {
                            ForEach(history.prefix(30)) { record in
                                HStack(spacing: 10) {
                                    Image(systemName: historySymbol(record.action))
                                        .foregroundStyle(historyColor(record.action))
                                        .frame(width: 16)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(record.path)
                                            .font(.system(size: 12.5, weight: .medium))
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        HStack(spacing: 5) {
                                            Text(historyAction(record.action))
                                            Text("·")
                                            Text(historyScope(record.scope))
                                            if let detail = record.detail, !detail.isEmpty {
                                                Text("·")
                                                Text(historyDetail(detail))
                                            }
                                        }
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(MoniPalette.foregroundTertiary)
                                        .lineLimit(1)
                                    }
                                    Spacer(minLength: 8)
                                    Text(record.date.formatted(date: .omitted, time: .shortened))
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(MoniPalette.foregroundTertiary)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(MoniPalette.inset)
                                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            }
                        }
                    }

                    if let historyError {
                        Text(historyError)
                            .font(.system(size: 11.5))
                            .foregroundStyle(MoniPalette.red)
                    }
                }
            }
        }
        .task {
            reloadWhitelist()
            history = await CleanupService.shared.history()
        }
        .alert("Clear operation history?", isPresented: $confirmsHistoryClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                Task { await clearHistory() }
            }
        } message: {
            Text("This removes Moni's local cleanup audit history. It does not delete any files.")
        }
    }

    private func chooseProtectedPaths() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.prompt = MoniLocalization.string("Protect")
        guard panel.runModal() == .OK else { return }
        CleanupPreferences.addToWhitelist(panel.urls.map(\.path))
        reloadWhitelist()
    }

    private func reloadWhitelist() {
        whitelist = CleanupPreferences.whitelist()
    }

    private func clearHistory() async {
        do {
            try await CleanupService.shared.clearHistory()
            history = []
            historyError = nil
        } catch {
            historyError = error.localizedDescription
        }
    }

    private func historyAction(_ action: CleanupOperationAction) -> String {
        let key = switch action {
        case .previewed: "Previewed"
        case .trashed: "Moved to Trash"
        case .skipped: "Skipped"
        case .failed: "Failed"
        }
        return MoniLocalization.string(key)
    }

    private func historyScope(_ scope: CleanupScope) -> String {
        let key = switch scope {
        case .diskBrowser: "Disk Browser"
        case .cacheAndLogs: "Caches & Logs"
        case .caches: "Caches"
        case .logs: "Logs"
        case .projects: "Projects"
        case .installers: "Installers"
        case .applications: "Applications"
        case .maintenance: "Maintenance"
        }
        return MoniLocalization.string(key)
    }

    private func historyDetail(_ detail: String) -> String {
        guard let rejection = CleanupRejection(rawValue: detail) else { return detail }
        let key = switch rejection {
        case .invalidPath: "Invalid path"
        case .missing: "Item no longer exists"
        case .protected: "System-protected path"
        case .whitelisted: "Custom protected path"
        case .changed: "Item changed after preview"
        case .expired: "Preview expired"
        }
        return MoniLocalization.string(key)
    }

    private func historySymbol(_ action: CleanupOperationAction) -> String {
        switch action {
        case .previewed: "eye"
        case .trashed: "trash"
        case .skipped: "shield"
        case .failed: "exclamationmark.triangle"
        }
    }

    private func historyColor(_ action: CleanupOperationAction) -> Color {
        switch action {
        case .previewed: MoniPalette.blue
        case .trashed: MoniPalette.green
        case .skipped: MoniPalette.orange
        case .failed: MoniPalette.red
        }
    }
}

private struct AboutSettings: View {
    @EnvironmentObject private var monitor: SystemMonitor
    @EnvironmentObject private var updates: UpdateController
    @State private var exportError: String?

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 104, height: 104)

            VStack(spacing: 6) {
                Text("Moni \(version)")
                    .font(.system(size: 24, weight: .heavy))
                    .tracking(-0.6)
                Text("Build \(build) · \(architecture) · \(ProcessInfo.processInfo.operatingSystemVersionString)")
                    .font(.system(size: 12.5))
                    .foregroundStyle(MoniPalette.foregroundTertiary)
            }

            HStack(spacing: 8) {
                AboutActionButton(
                    title: "Check for updates",
                    systemImage: "arrow.triangle.2.circlepath"
                ) {
                    updates.checkForUpdates()
                }
                .disabled(!updates.canCheckForUpdates)

                AboutActionButton(
                    title: "Export diagnostics…",
                    systemImage: "square.and.arrow.up"
                ) {
                    exportDiagnostics()
                }

                AboutActionButton(
                    title: "Quit Moni",
                    systemImage: "power",
                    isDestructive: true
                ) {
                    NSApp.terminate(nil)
                }
            }

            if let exportError {
                Text(exportError)
                    .font(.system(size: 12))
                    .foregroundStyle(MoniPalette.red)
            } else if let configurationError = updates.configurationError {
                Text(configurationError)
                    .font(.system(size: 12))
                    .foregroundStyle(MoniPalette.foregroundTertiary)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var architecture: String {
#if arch(arm64)
        "Apple silicon"
#else
        "Intel"
#endif
    }

    private func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Moni Diagnostics.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let snapshot = monitor.snapshot
        let report = """
        Moni \(version) (\(build))
        \(ProcessInfo.processInfo.operatingSystemVersionString)
        Host: \(snapshot.host.name)
        CPU: \(Int(snapshot.cpu.total.rounded()))%
        Memory: \(Int(snapshot.memory.usedPercent.rounded()))%
        Volumes: \(snapshot.volumes.count)
        Generated: \(Date.now.formatted())
        """
        do {
            try report.write(to: url, atomically: true, encoding: .utf8)
            exportError = nil
        } catch {
            exportError = error.localizedDescription
        }
    }
}

private struct AboutActionButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    let title: String
    let systemImage: String
    var isDestructive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(MoniLocalization.string(title), systemImage: systemImage)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(isDestructive ? MoniPalette.red : MoniPalette.foreground)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(backgroundColor)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(MoniPressButtonStyle())
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : MoniMotion.press, value: isHovered)
    }

    private var backgroundColor: Color {
        if isDestructive {
            return MoniPalette.red.opacity(isHovered ? 0.22 : 0.14)
        }
        return isHovered ? MoniPalette.controlHover : MoniPalette.control
    }
}
