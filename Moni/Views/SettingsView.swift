import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, menuBar, alerts, aiUsage, modules, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .menuBar: "Menu Bar"
        case .alerts: "Alerts"
        case .aiUsage: "AI Providers"
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
                        .foregroundStyle(.tertiary)
                    Text("Sampling \(samplingLabel)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
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
    var expand = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
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
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(MoniPalette.foreground)
                    Text(hint)
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 12)
                SettingsSwitch(isOn: isOn)
            }
            .padding(.horizontal, 10)
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

private struct AIUsageSettings: View {
    @EnvironmentObject private var store: AIUsageStore
    @AppStorage(PreferenceKey.aiUsageRange) private var rangeValue = AIUsageRange.month.rawValue
    @AppStorage(PreferenceKey.disabledAIProviders) private var disabledProviderValue = ""

    private static let knownProviders = [
        "Claude", "Codex", "Gemini CLI", "Qwen Code", "Kimi Code",
        "DeepSeek Harness", "OpenCode", "GitHub Copilot", "Grok",
    ]

    private var range: AIUsageRange {
        AIUsageRange(rawValue: rangeValue) ?? .month
    }

    private var detectedProviders: [AIProviderUsage] {
        store.summary.providers.filter {
            $0.totalTokens > 0 || $0.sessionCount > 0 || !$0.quotaWindows.isEmpty
        }
    }

    private var providerNames: [String] {
        let known = Set(Self.knownProviders)
        return Self.knownProviders + detectedProviders.map(\.provider).filter { !known.contains($0) }
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 12) {
                DetailPanel("Providers") {
                    VStack(spacing: 2) {
                        ForEach(providerNames, id: \.self) { providerName in
                            providerRow(
                                providerName,
                                usage: detectedProviders.first { $0.provider == providerName }
                            )
                        }
                    }

                    HStack(spacing: 8) {
                        Button {
                            store.refresh(
                                range: range,
                                includeQuotas: true,
                                allowKeychainPrompt: true
                            )
                        } label: {
                            HStack(spacing: 7) {
                                Text("Rescan now")
                                if store.isLoading {
                                    ProgressView()
                                        .controlSize(.mini)
                                }
                            }
                            .font(.system(size: 12.5))
                            .foregroundStyle(MoniPalette.foreground)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(MoniPalette.control)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(store.isLoading)
                        .moniPointingHand()
                    }
                }

                DetailPanel("Default range") {
                    HStack(spacing: 6) {
                        ForEach(AIUsageRange.allCases) { item in
                            Button {
                                rangeValue = item.rawValue
                            } label: {
                                Text(item.title)
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundStyle(range == item ? Color.white : MoniPalette.foregroundSecondary)
                                    .padding(.horizontal, 13)
                                    .padding(.vertical, 7)
                                    .background(range == item ? MoniPalette.blue : MoniPalette.control)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .moniPointingHand()
                        }
                    }

                    Text("Costs are estimated from local logs at API list prices — they are not your subscription invoice.")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 4)
                }
            }
        }
        .onChange(of: rangeValue) { _, value in
            store.refresh(range: AIUsageRange(rawValue: value) ?? .month, includeQuotas: true)
        }
        .task {
            store.loadIfNeeded(range: range, includeQuotas: true)
        }
        .moniAnimation(value: store.isLoading)
    }

    private func providerRow(_ providerName: String, usage: AIProviderUsage?) -> some View {
        let isDetected = usage != nil

        return Button {
            toggleProvider(providerName)
        } label: {
            HStack(spacing: 12) {
                Image(providerIconName(providerName))
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(isDetected ? providerColor(providerName) : MoniPalette.foregroundSecondary.opacity(0.4))
                    .frame(width: 18, height: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName(providerName))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isDetected ? MoniPalette.foreground : Color.secondary.opacity(0.55))
                    Text(usage.map(providerSource) ?? (isProviderEnabled(providerName) ? "Not detected" : "Turned off"))
                        .font(.system(size: 12))
                        .foregroundStyle(isDetected ? Color.secondary.opacity(0.65) : Color.secondary.opacity(0.4))
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                Text(usage?.totalTokens.formatted(.number.notation(.compactName)) ?? "—")
                    .font(.system(size: 12))
                    .foregroundStyle(isDetected ? Color.secondary.opacity(0.65) : Color.secondary.opacity(0.4))
                    .monospacedDigit()

                SettingsSwitch(isOn: isDetected && isProviderEnabled(providerName))
                    .opacity(isDetected ? 1 : 0.6)
            }
            .padding(10)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        // A provider that was switched off may stop being detected (its quota is
        // no longer fetched); the row has to stay tappable or it can never be
        // switched back on.
        .disabled(!isDetected && isProviderEnabled(providerName))
        .moniPointingHand()
        .moniAnimation(value: disabledProviderValue)
    }

    private var disabledProviders: Set<String> {
        Set(disabledProviderValue.split(separator: ",").map(String.init))
    }

    private func isProviderEnabled(_ provider: String) -> Bool {
        !disabledProviders.contains(provider)
    }

    private func toggleProvider(_ provider: String) {
        var disabled = disabledProviders
        if !disabled.insert(provider).inserted {
            disabled.remove(provider)
        }
        disabledProviderValue = disabled.sorted().joined(separator: ",")
    }

    private func displayName(_ provider: String) -> String {
        provider == "Claude" ? "Claude Code" : provider
    }

    private func providerSource(_ provider: AIProviderUsage) -> String {
        let source: String = switch provider.provider {
        case "Claude": "~/.claude/projects"
        case "Codex": "~/.codex/sessions"
        case "Gemini CLI": "~/.gemini"
        case "Qwen Code": "~/.qwen"
        case "Kimi Code": "~/.kimi-code"
        case "DeepSeek Harness": "~/.dsh/sessions"
        case "OpenCode": "~/.local/share/opencode"
        default: "Local logs"
        }
        guard let lastUpdated = provider.lastUpdated else { return source }
        return "\(source) · updated \(relativeAge(lastUpdated)) ago"
    }

    private func relativeAge(_ date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3_600 { return "\(seconds / 60)m" }
        if seconds < 86_400 { return "\(seconds / 3_600)h" }
        return "\(seconds / 86_400)d"
    }

    private func providerColor(_ provider: String) -> Color {
        switch provider {
        case "Claude": Color(red: 204 / 255, green: 124 / 255, blue: 94 / 255)
        case "Codex": Color(red: 73 / 255, green: 163 / 255, blue: 176 / 255)
        case "Gemini CLI": Color(red: 171 / 255, green: 135 / 255, blue: 234 / 255)
        case "Qwen Code": Color(red: 1, green: 106 / 255, blue: 0)
        case "Kimi Code": Color(red: 254 / 255, green: 96 / 255, blue: 60 / 255)
        case "DeepSeek Harness": Color(red: 0.32, green: 0.49, blue: 0.94)
        case "OpenCode": Color(red: 59 / 255, green: 130 / 255, blue: 246 / 255)
        case "GitHub Copilot": Color(red: 168 / 255, green: 85 / 255, blue: 247 / 255)
        case "Grok": Color(red: 16 / 255, green: 163 / 255, blue: 127 / 255)
        default: MoniPalette.foregroundSecondary
        }
    }

    private func providerIconName(_ provider: String) -> String {
        switch provider {
        case "Claude": "ProviderIcon-claude"
        case "Codex": "ProviderIcon-codex"
        case "Gemini CLI": "ProviderIcon-gemini"
        case "Qwen Code": "ProviderIcon-alibaba"
        case "Kimi Code": "ProviderIcon-kimi"
        case "DeepSeek Harness": "ProviderIcon-deepseek"
        case "OpenCode": "ProviderIcon-opencode"
        case "GitHub Copilot": "ProviderIcon-copilot"
        case "Grok": "ProviderIcon-grok"
        default: "ProviderIcon-codex"
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
                            .foregroundStyle(.tertiary)
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
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(hint)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
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
    @AppStorage(PreferenceKey.appearance) private var appearance = AppAppearance.system.rawValue
    @AppStorage(PreferenceKey.samplingInterval) private var samplingInterval = 0.7
    @AppStorage(PreferenceKey.notificationAlerts) private var notificationAlerts = false
    @AppStorage(PreferenceKey.showDockIcon) private var showDockIcon = false
    @AppStorage(PreferenceKey.compactMenuBar) private var compactMenuBar = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemError: String?
    @State private var notificationError: String?

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 12) {
                DetailPanel("Appearance") {
                    HStack(spacing: 6) {
                        SettingsChoiceButton(title: "Dark", selected: storedAppearance == .dark, expand: true) {
                            appearance = AppAppearance.dark.rawValue
                        }
                        SettingsChoiceButton(title: "Light", selected: storedAppearance == .light, expand: true) {
                            appearance = AppAppearance.light.rawValue
                        }
                        SettingsChoiceButton(title: "Auto", selected: storedAppearance == .system, expand: true) {
                            appearance = AppAppearance.system.rawValue
                        }
                    }
                    Text(
                        storedAppearance == .system
                            ? "Auto follows the macOS appearance, currently \(colorScheme == .dark ? "dark" : "light")."
                            : "Light mode follows the same palette with inverted surfaces."
                    )
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
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
                        .foregroundStyle(.tertiary)
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
                            hint: "Percentage only, no mini graph",
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
    @AppStorage(PreferenceKey.menuBarMetric) private var metric = MenuBarMetric.cpu.rawValue
    @AppStorage(PreferenceKey.menuBarItems) private var itemValue = "cpu,memory"
    @AppStorage(PreferenceKey.menuBarDisplayStyle) private var styleValue = MenuBarDisplayStyle.valueOnly.rawValue

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 12) {
                DetailPanel("Preview") {
                    HStack(spacing: 14) {
                        Spacer()
                        ForEach(Array(selectedMetrics.prefix(3))) { item in
                            HStack(spacing: 5) {
                                Text(previewTag(item))
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(metricColor(item))
                                Text(previewValue(item))
                                    .font(.system(size: 12, weight: .semibold))
                                    .monospacedDigit()
                            }
                        }
                        Text(Date.now.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
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
                        .foregroundStyle(.secondary)
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
        item == .temperature ? "TMP" : String(item.title.prefix(3)).uppercased()
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
    @EnvironmentObject private var aiUsage: AIUsageStore
    @AppStorage(PreferenceKey.showHost) private var showHost = true
    @AppStorage(PreferenceKey.showCPU) private var showCPU = true
    @AppStorage(PreferenceKey.showMemory) private var showMemory = true
    @AppStorage(PreferenceKey.showGPU) private var showGPU = true
    @AppStorage(PreferenceKey.showNetwork) private var showNetwork = true
    @AppStorage(PreferenceKey.showStorage) private var showStorage = true
    @AppStorage(PreferenceKey.showProcesses) private var showProcesses = true
    @AppStorage(PreferenceKey.showPower) private var showPower = true
    @AppStorage(PreferenceKey.showAI) private var showAI = true
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
                            "AI Usage",
                            color: MoniPalette.indigo,
                            note: count(aiUsage.summary.providers.count, singular: "account"),
                            isOn: $showAI
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
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 12)
                Text(note)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
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
        "\(value.formatted()) \(singular)\(value == 1 ? "" : "s")"
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
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 12) {
                DetailPanel {
                    Text("Moni \(version)")
                        .font(.system(size: 22, weight: .heavy))
                        .tracking(-0.6)
                    Text("Build \(build) · \(architecture) · \(ProcessInfo.processInfo.operatingSystemVersionString)")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.tertiary)

                    HStack(spacing: 8) {
                        aboutButton("Check for updates") {
                            updates.checkForUpdates()
                        }
                        .disabled(!updates.canCheckForUpdates)

                        aboutButton("Export diagnostics…") {
                            exportDiagnostics()
                        }

                        Button {
                            NSApp.terminate(nil)
                        } label: {
                            Text("Quit Moni")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(MoniPalette.red)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(MoniPalette.red.opacity(0.14))
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(MoniPressButtonStyle())
                    }

                    if let exportError {
                        Text(exportError)
                            .font(.system(size: 12))
                            .foregroundStyle(MoniPalette.red)
                    } else if let configurationError = updates.configurationError {
                        Text(configurationError)
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                }

                DetailPanel("Shortcuts") {
                    LazyVGrid(
                        columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())],
                        spacing: 10
                    ) {
                        shortcut("Refresh now", "⌘R")
                        shortcut("Settings", "⌘,")
                        shortcut("Quit", "⌘Q")
                    }
                }
            }
        }
    }

    private var architecture: String {
#if arch(arm64)
        "Apple silicon"
#else
        "Intel"
#endif
    }

    private func aboutButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5))
                .foregroundStyle(MoniPalette.foreground)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(MoniPalette.control)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(MoniPressButtonStyle())
    }

    private func shortcut(_ title: String, _ keys: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(MoniPalette.foregroundSecondary)
            Spacer()
            Text(keys)
                .fontWeight(.semibold)
                .foregroundStyle(MoniPalette.foreground)
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(MoniPalette.inset)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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
