import SwiftUI
import WidgetKit

private enum DashboardSizing {
    static let designWidth: CGFloat = 900
    static let designHeight: CGFloat = 850
    static let toolbarContentSpacing: CGFloat = 10
    static let contentTopPadding: CGFloat = 14
    static let contentBottomPadding: CGFloat = 18
}

private enum StatusBarAction {
    case refresh
    case settings
    case quit
}

enum MonitorSection: String, CaseIterable, Identifiable {
    case summary, host, cpu, memory, gpu, network, storage, processes, sensors, docker, disks, settings

    var id: String { rawValue }

    var title: String {
        let key: String = switch self {
        case .summary: "Summary"
        case .host: "Host"
        case .cpu: "CPU"
        case .memory: "Memory"
        case .gpu: "GPU"
        case .network: "Network"
        case .storage: "Storage"
        case .processes: "Processes"
        case .sensors: "Power & Sensors"
        case .docker: "Docker"
        case .disks: "Disk Browser"
        case .settings: "Settings"
        }
        return MoniLocalization.string(key)
    }

    var symbol: String {
        switch self {
        case .summary: "chart.bar"
        case .host: "server.rack"
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .gpu: "display"
        case .network: "arrow.up.arrow.down"
        case .storage: "internaldrive"
        case .processes: "list.bullet.rectangle"
        case .sensors: "bolt.batteryblock"
        case .docker: "cube"
        case .disks: "folder"
        case .settings: "gearshape"
        }
    }

    var accentColor: Color {
        switch self {
        case .summary: MoniPalette.foreground
        case .host, .memory, .docker: MoniPalette.blue
        case .cpu: MoniPalette.pink
        case .gpu: MoniPalette.green
        case .network: MoniPalette.cyan
        case .storage: MoniPalette.orange
        case .processes: MoniPalette.purple
        case .sensors: MoniPalette.yellow
        case .disks, .settings: MoniPalette.foregroundTertiary
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var monitor: SystemMonitor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selection: MonitorSection = .summary
    @State private var hoveredSection: MonitorSection?
    @State private var settingsSection: SettingsSection = .general
    @State private var hostContentHeight: CGFloat?
    @State private var toolbarHeight: CGFloat = 0
    @State private var statusBarHeight: CGFloat = 0
    @State private var hoveredStatusBarAction: StatusBarAction?
    @AppStorage(PreferenceKey.appearance) private var appearance = AppAppearance.system.rawValue
    @AppStorage(PreferenceKey.appLanguage) private var appLanguage = AppLanguage.english.rawValue
    @AppStorage(PreferenceKey.samplingInterval) private var samplingInterval = 0.7
    @AppStorage(PreferenceKey.showDockIcon) private var showDockIcon = false
    @AppStorage(PreferenceKey.windowZoom) private var windowZoom = 1.0

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: DashboardSizing.toolbarContentSpacing) {
                toolbar
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { height in
                        toolbarHeight = height
                    }

                ZStack(alignment: .topLeading) {
                    Group {
                        if selection == .summary {
                            SummaryView(selection: animatedSelection)
                        } else if [.host, .cpu, .memory, .processes].contains(selection) {
                            PrimaryDetailView(
                                section: selection,
                                selection: animatedSelection,
                                onHostContentHeightChange: { height in
                                    hostContentHeight = height
                                }
                            )
                        } else if [.gpu, .network, .storage, .sensors, .docker, .disks].contains(selection) {
                            SecondaryDetailView(section: selection, selection: animatedSelection)
                        } else if selection == .settings {
                            SettingsView(section: $settingsSection)
                        } else {
                            ModulePlaceholder(section: selection) {
                                select(.summary)
                            }
                        }
                    }
                    .id(selection)
                    .transition(reduceMotion ? .identity : MoniMotion.pageTransition)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .moniAnimation(MoniMotion.navigation, value: selection)
            }
            .padding(.horizontal, 16)
            .padding(.top, DashboardSizing.contentTopPadding)
            .padding(.bottom, DashboardSizing.contentBottomPadding)

            statusBar
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    statusBarHeight = height
                }
        }
        .frame(
            width: DashboardSizing.designWidth,
            height: windowHeight,
            alignment: .topLeading
        )
        .foregroundStyle(MoniPalette.foreground)
        .tint(MoniPalette.blue)
        .background(MoniPalette.panel)
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
            WidgetCenter.shared.reloadAllTimelines()
        }
        .onChange(of: samplingInterval) { _, value in
            monitor.setSamplingInterval(value)
        }
        .onChange(of: showDockIcon) { _, value in
            NSApp.setActivationPolicy(value ? .regular : .accessory)
        }
        .scaleEffect(renderedScale, anchor: .topLeading)
        .frame(
            width: DashboardSizing.designWidth * renderedScale,
            height: windowHeight * renderedScale,
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

    private var windowHeight: CGFloat {
        guard selection == .host,
              let hostContentHeight,
              toolbarHeight > 0,
              statusBarHeight > 0
        else {
            return DashboardSizing.designHeight
        }

        let fittedHeight = DashboardSizing.contentTopPadding
            + toolbarHeight
            + DashboardSizing.toolbarContentSpacing
            + hostContentHeight
            + DashboardSizing.contentBottomPadding
            + statusBarHeight
        return min(DashboardSizing.designHeight, ceil(fittedHeight))
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

    private var animatedSelection: Binding<MonitorSection> {
        Binding(get: { selection }, set: select)
    }

    private func select(_ section: MonitorSection) {
        guard section != selection else { return }
        selection = section
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach(MonitorSection.allCases.filter { $0 != .settings }) { section in
                    Button {
                        select(section)
                    } label: {
                        Image(systemName: section.symbol)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 17, height: 17)
                            .frame(width: 38, height: 30)
                            .foregroundStyle(selection == section ? section.accentColor : MoniPalette.foregroundTertiary)
                            .background(
                                selection == section
                                    ? MoniPalette.controlSelected
                                    : hoveredSection == section ? MoniPalette.controlHover : Color.clear
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(MoniPressButtonStyle())
                    .help(MoniLocalization.string(section.title))
                    .onHover { isHovered in
                        if isHovered {
                            hoveredSection = section
                        } else if hoveredSection == section {
                            hoveredSection = nil
                        }
                    }
                    .animation(reduceMotion ? nil : MoniMotion.press, value: hoveredSection)
                }
            }
            .padding(4)
            .background(MoniPalette.control)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            Spacer()

            Button {
                settingsSection = .general
                select(.settings)
            } label: {
                Image(systemName: "gearshape")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 18, height: 18)
                    .frame(width: 34, height: 34)
                    .background(selection == .settings ? MoniPalette.controlSelected : MoniPalette.control)
                    .clipShape(Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(MoniPressButtonStyle())
            .help(MoniLocalization.string("Settings"))
            .keyboardShortcut(",", modifiers: .command)
        }
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
                    monitor.loadNetworkExternalDetailsIfNeeded(force: true)
                }
                statusBarButton("Settings", shortcut: "⌘,", action: .settings) {
                    settingsSection = .general
                    select(.settings)
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

private struct ModulePlaceholder: View {
    let section: MonitorSection
    let back: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: section.symbol)
                .font(.system(size: 42))
                .foregroundStyle(MoniPalette.foregroundSecondary)
            Text(section.title)
                .font(.title2.bold())
            Button("Back to summary", action: back)
                .moniPointingHand()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MoniPalette.card)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

#Preview {
    ContentView()
        .environmentObject(SystemMonitor())
}
