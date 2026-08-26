import AppKit
import SwiftUI

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
        case .summary: "chart.bar.fill"
        case .host: "server.rack"
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .gpu: "display"
        case .network: "arrow.up.arrow.down"
        case .storage: "internaldrive"
        case .processes: "list.bullet.rectangle"
        case .sensors: "battery.75percent"
        case .ai: "sparkles"
        case .docker: "shippingbox"
        case .disks: "folder"
        case .settings: "gearshape"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var monitor: SystemMonitor
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selection: MonitorSection = .summary
    @State private var refreshRotation = 0.0
    @AppStorage(PreferenceKey.appearance) private var appearance = AppAppearance.system.rawValue
    @AppStorage(PreferenceKey.samplingInterval) private var samplingInterval = 1.0
    @AppStorage(PreferenceKey.showDockIcon) private var showDockIcon = false

    var body: some View {
        VStack(spacing: 12) {
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
                        AIUsageView()
                    } else if selection == .settings {
                        SettingsView()
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
        .padding(16)
        .frame(width: 900, height: 720, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(preferredColorScheme)
        .onAppear {
            monitor.setSamplingInterval(samplingInterval)
            applyDockIconPreference(showDockIcon)
        }
        .onChange(of: samplingInterval) { _, value in
            monitor.setSamplingInterval(value)
        }
        .onChange(of: showDockIcon) { _, value in
            applyDockIconPreference(value)
            if value {
                openWindow(id: "dashboard")
            }
        }
    }

    private var preferredColorScheme: ColorScheme? {
        switch AppAppearance(rawValue: appearance) ?? .system {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    private func applyDockIconPreference(_ isVisible: Bool) {
        NSApp.setActivationPolicy(isVisible ? .regular : .accessory)
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
                ForEach(MonitorSection.allCases.filter { $0 != .disks && $0 != .settings }) { section in
                    Button {
                        select(section)
                    } label: {
                        Image(systemName: section.symbol)
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 28, height: 28)
                            .foregroundStyle(selection == section ? .white : .secondary)
                            .background(selection == section ? Color.accentColor : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    .buttonStyle(MoniPressButtonStyle())
                    .help(section.title)
                }
            }
            .padding(4)
            .background(Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))

            Spacer()

            Button {
                monitor.refresh(forceSlowMetrics: true)
                if !reduceMotion {
                    withAnimation(.easeInOut(duration: 0.45)) {
                        refreshRotation += 360
                    }
                }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 30, height: 30)
                    .rotationEffect(.degrees(refreshRotation))
                    .contentShape(Rectangle())
            }
            .buttonStyle(MoniPressButtonStyle())
            .help("Refresh")

            Button {
                select(.settings)
            } label: {
                Image(systemName: "gearshape")
                    .frame(width: 30, height: 30)
                    .background(selection == .settings ? Color.primary.opacity(0.12) : Color.primary.opacity(0.06))
                    .clipShape(Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(MoniPressButtonStyle())
            .help("Settings")
        }
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.primary.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

#Preview {
    ContentView()
        .environmentObject(SystemMonitor())
        .environmentObject(AIUsageStore())
}
