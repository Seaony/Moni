import SwiftUI

private enum DashboardSizing {
    static let contentHorizontalPadding: CGFloat = 16
    static let contentTopPadding: CGFloat = 14
    static let contentBottomPadding: CGFloat = 18
}

private enum StatusBarAction {
    case refresh
    case quit
}

struct ContentView: View {
    @EnvironmentObject private var monitor: SystemMonitor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isShowingSettings = false
    @State private var settingsSection: SettingsSection = .general
    @State private var summaryContentSize: CGSize?
    @State private var settingsContentSize: CGSize?
    @State private var contentSize: CGSize?
    @State private var statusBarHeight: CGFloat = 0
    @State private var hoveredStatusBarAction: StatusBarAction?
    @AppStorage(PreferenceKey.appearance) private var appearance = AppAppearance.system.rawValue
    @AppStorage(PreferenceKey.appLanguage) private var appLanguage = AppLanguage.english.rawValue
    @AppStorage(PreferenceKey.samplingInterval) private var samplingInterval = 0.7
    @AppStorage(PreferenceKey.showDockIcon) private var showDockIcon = false
    @AppStorage(PreferenceKey.windowZoom) private var windowZoom = 1.0

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if isShowingSettings {
                    SettingsView(section: $settingsSection) { settingsContentSize = $0 }
                        .onExitCommand { isShowingSettings = false }
                } else {
                    SummaryView { summaryContentSize = $0 }
                }
            }
            .frame(width: pageWidth, height: pageHeight, alignment: .topLeading)
            .padding(.horizontal, DashboardSizing.contentHorizontalPadding)
            .padding(.top, DashboardSizing.contentTopPadding)
            .padding(.bottom, DashboardSizing.contentBottomPadding)

            statusBar
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { statusBarHeight = $0 }
        }
        .frame(
            maxWidth: availableSize?.width,
            maxHeight: availableSize?.height,
            alignment: .topLeading
        )
        .fixedSize()
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { contentSize = $0 }
        .foregroundStyle(MoniPalette.foreground)
        .tint(MoniPalette.blue)
        .background(MoniPalette.panel)
        .background {
            Button(MoniLocalization.string("Settings")) {
                settingsSection = .general
                isShowingSettings = true
            }
            .keyboardShortcut(",", modifiers: .command)
            .hidden()
        }
        .preferredColorScheme(preferredColorScheme)
        .environment(\.locale, selectedLanguage.locale)
        .onAppear {
            MoniLocalization.setLanguage(selectedLanguage)
            applyAppearance(appearance)
            monitor.setSamplingInterval(samplingInterval)
            NSApp.setActivationPolicy(showDockIcon ? .regular : .accessory)
        }
        .onChange(of: appearance) { _, value in
            applyAppearance(value)
        }
        .onChange(of: appLanguage) { _, _ in
            MoniLocalization.setLanguage(selectedLanguage)
        }
        .onChange(of: samplingInterval) { _, value in
            monitor.setSamplingInterval(value)
        }
        .onChange(of: showDockIcon) { _, value in
            NSApp.setActivationPolicy(value ? .regular : .accessory)
        }
        .scaleEffect(renderedScale, anchor: .topLeading)
        .frame(
            width: contentSize.map { $0.width * renderedScale },
            height: contentSize.map { $0.height * renderedScale },
            alignment: .topLeading
        )
        .clipped()
    }

    private var renderedScale: CGFloat {
        CGFloat(windowZoom)
    }

    private var selectedLanguage: AppLanguage {
        AppLanguage(rawValue: appLanguage) ?? .english
    }

    private var availableSize: CGSize? {
        NSScreen.main.map {
            CGSize(width: $0.visibleFrame.width / renderedScale, height: $0.visibleFrame.height / renderedScale)
        }
    }

    private var pageContentSize: CGSize? {
        isShowingSettings ? settingsContentSize : summaryContentSize
    }

    private var pageWidth: CGFloat? {
        pageContentSize.map {
            min($0.width, (availableSize?.width ?? .infinity) - DashboardSizing.contentHorizontalPadding * 2)
        }
    }

    private var pageHeight: CGFloat? {
        pageContentSize.map {
            min($0.height, (availableSize?.height ?? .infinity) - DashboardSizing.contentTopPadding
                - DashboardSizing.contentBottomPadding - statusBarHeight)
        }
    }

    private var preferredColorScheme: ColorScheme? {
        switch AppAppearance(rawValue: appearance) ?? .system {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    private func applyAppearance(_ value: String) {
        switch AppAppearance(rawValue: value) ?? .system {
        case .system:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    private func refreshSystem() {
        monitor.refresh(forceSlowMetrics: true)
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(MoniPalette.green)
                .frame(width: 7, height: 7)

            Text(statusText)
                .monospacedDigit()

            Spacer()

            HStack(spacing: 2) {
                statusBarButton("Refresh", shortcut: "⌘R", action: .refresh) {
                    monitor.refresh(forceSlowMetrics: true)
                }
                statusBarButton("Quit", shortcut: "⌘Q", action: .quit) {
                    NSApp.terminate(nil)
                }
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(MoniPalette.foregroundTertiary)
        .padding(.horizontal, 18)
        .padding(.vertical, 7)
        .background(MoniPalette.inset)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(MoniPalette.footerLine)
                .frame(height: 1)
        }
    }

    private func statusBarButton(
        _ title: String,
        shortcut: String,
        action: StatusBarAction,
        perform: @escaping () -> Void
    ) -> some View {
        Button(action: perform) {
            HStack(spacing: 4) {
                Text(MoniLocalization.string(title))
                Text(shortcut)
                    .foregroundStyle(MoniPalette.foregroundQuaternary)
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .foregroundStyle(
                hoveredStatusBarAction == action
                    ? MoniPalette.foregroundSecondary
                    : MoniPalette.foregroundTertiary
            )
            .background(
                hoveredStatusBarAction == action
                    ? MoniPalette.controlHover
                    : Color.clear
            )
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(MoniPressButtonStyle(scale: 0.98))
        .onHover { isHovered in
            if isHovered {
                hoveredStatusBarAction = action
            } else if hoveredStatusBarAction == action {
                hoveredStatusBarAction = nil
            }
        }
        .animation(reduceMotion ? nil : MoniMotion.press, value: hoveredStatusBarAction)
    }

    private var statusText: String {
        var parts = [
            MoniLocalization.format("Sampling every %@", formattedSamplingInterval),
            "\(Int(monitor.snapshot.cpu.total.rounded()))% CPU",
            "\(Int(monitor.snapshot.memory.usedPercent.rounded()))% MEM"
        ]
        if let temperature = monitor.snapshot.power.cpuTemperatureCelsius {
            parts.append("\(Int(temperature.rounded()))°C")
        }
        return parts.joined(separator: " · ")
    }

    private var formattedSamplingInterval: String {
        samplingInterval.rounded() == samplingInterval
            ? "\(Int(samplingInterval))s"
            : String(format: "%.1fs", samplingInterval)
    }
}

#Preview {
    ContentView()
        .environmentObject(SystemMonitor())
}
