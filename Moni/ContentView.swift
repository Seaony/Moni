import SwiftUI

private enum DashboardSizing {
    static let designWidth: CGFloat = 900
    static let designHeight: CGFloat = 850
    static let interfaceScale: CGFloat = 1.0
    static let renderedWidth = designWidth * interfaceScale
    static let renderedHeight = designHeight * interfaceScale
}

enum MonitorSection: String, CaseIterable, Identifiable {
    case summary, host, cpu, memory, gpu, network, storage, processes, sensors, ai, docker, disks, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .summary: "Summary"
        case .host: "Host"
        case .cpu: "CPU"
        case .memory: "Memory"
        case .gpu: "GPU"
        case .network: "Network"
        case .storage: "Storage"
        case .processes: "Processes"
        case .sensors: "Power & Sensors"
        case .ai: "AI Usage"
        case .docker: "Docker"
        case .disks: "Disk Browser"
        case .settings: "Settings"
        }
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
        case .ai: "sparkles"
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
        case .ai: MoniPalette.indigo
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
    @AppStorage(PreferenceKey.appearance) private var appearance = AppAppearance.system.rawValue
    @AppStorage(PreferenceKey.samplingInterval) private var samplingInterval = 0.7
    @AppStorage(PreferenceKey.showDockIcon) private var showDockIcon = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                toolbar

                ZStack(alignment: .topLeading) {
                    Group {
                        if selection == .summary {
                            SummaryView(selection: animatedSelection)
                        } else if [.host, .cpu, .memory, .processes].contains(selection) {
                            PrimaryDetailView(section: selection, selection: animatedSelection)
                        } else if [.gpu, .network, .storage, .sensors, .docker, .disks].contains(selection) {
                            SecondaryDetailView(section: selection, selection: animatedSelection)
                        } else if selection == .ai {
                            AIUsageView {
                                settingsSection = .aiUsage
                                select(.settings)
                            }
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
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 18)

            statusBar
        }
        .frame(
            width: DashboardSizing.designWidth,
            height: DashboardSizing.designHeight,
            alignment: .topLeading
        )
        .foregroundStyle(MoniPalette.foreground)
        .tint(MoniPalette.blue)
        .background(MoniPalette.panel)
        .preferredColorScheme(preferredColorScheme)
        .onAppear {
            monitor.setSamplingInterval(samplingInterval)
            NSApp.setActivationPolicy(showDockIcon ? .regular : .accessory)
        }
        .onChange(of: samplingInterval) { _, value in
            monitor.setSamplingInterval(value)
        }
        .onChange(of: showDockIcon) { _, value in
            NSApp.setActivationPolicy(value ? .regular : .accessory)
        }
        .scaleEffect(DashboardSizing.interfaceScale, anchor: .topLeading)
        .frame(
            width: DashboardSizing.renderedWidth,
            height: DashboardSizing.renderedHeight,
            alignment: .topLeading
        )
        .clipped()
    }

    private var preferredColorScheme: ColorScheme? {
        switch AppAppearance(rawValue: appearance) ?? .system {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    private var animatedSelection: Binding<MonitorSection> {
        Binding(get: { selection }, set: select)
    }

    private func select(_ section: MonitorSection) {
        guard section != selection else { return }
        if reduceMotion {
            selection = section
        } else {
            withAnimation(MoniMotion.navigation) {
                selection = section
            }
        }
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
                    .help(section.title)
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
            .help("Settings")
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

            Text("⌘R refresh")
            Text("⌘, settings")
            Text("⌘Q quit")
        }
        .font(.system(size: 12))
        .foregroundStyle(MoniPalette.foregroundTertiary)
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(MoniPalette.inset)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(MoniPalette.footerLine)
                .frame(height: 1)
        }
    }

    private var statusText: String {
        var parts = [
            "Sampling every \(formattedSamplingInterval)",
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
                .foregroundStyle(.secondary)
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
        .environmentObject(AIUsageStore())
}
