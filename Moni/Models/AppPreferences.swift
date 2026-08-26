import Foundation

enum PreferenceKey {
    static let appearance = "appearance"
    static let compactMenuBar = "compactMenuBar"
    static let launchAtLogin = "launchAtLogin"
    static let menuBarMetric = "menuBarMetric"
    static let samplingInterval = "samplingInterval"
    static let showDockIcon = "showDockIcon"

    static let showHost = "showHost"
    static let showCPU = "showCPU"
    static let showMemory = "showMemory"
    static let showGPU = "showGPU"
    static let showNetwork = "showNetwork"
    static let showStorage = "showStorage"
    static let showProcesses = "showProcesses"
    static let showPower = "showPower"
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum MenuBarMetric: String, CaseIterable, Identifiable {
    case cpu, memory, network, disk, battery

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .network: "Network"
        case .disk: "Disk"
        case .battery: "Battery"
        }
    }

    var symbol: String {
        switch self {
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .network: "arrow.down"
        case .disk: "internaldrive"
        case .battery: "battery.75percent"
        }
    }
}
