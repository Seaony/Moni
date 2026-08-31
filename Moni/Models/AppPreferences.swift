import Foundation

enum PreferenceKey {
    static let appLanguage = MoniLocalization.preferenceKey
    static let appearance = "appearance"
    static let compactMenuBar = "compactMenuBar"
    static let menuBarItems = "menuBarItems"
    static let menuBarDisplayStyle = "menuBarDisplayStyle"
    static let showDockIcon = "showDockIcon"
    static let launchAtLogin = "launchAtLogin"
    static let menuBarMetric = "menuBarMetric"
    static let samplingInterval = "samplingInterval"
    static let windowZoom = "windowZoom"
    static let cpuAlertThreshold = "cpuAlertThreshold"
    static let memoryAlertThreshold = "memoryAlertThreshold"
    static let diskAlertThreshold = "diskAlertThreshold"
    static let temperatureAlertThreshold = "temperatureAlertThreshold"
    static let notificationAlerts = "notificationAlerts"
    static let alertSounds = "alertSounds"
    static let repeatAlerts = "repeatAlerts"
    static let summaryCardLayout = "summaryCardLayout"
    static let summaryGridDensity = "summaryGridDensity"
    static let storageFolderCache = "storageFolderCache"
    static let storageFolderCacheDate = "storageFolderCacheDate"
    nonisolated static let cleanupWhitelist = "cleanupWhitelist"

    static let showHost = "showHost"
    static let showCPU = "showCPU"
    static let showMemory = "showMemory"
    static let showGPU = "showGPU"
    static let showNetwork = "showNetwork"
    static let showStorage = "showStorage"
    static let showProcesses = "showProcesses"
    static let showPower = "showPower"
    static let showDocker = "showDocker"
}

enum SummaryGridDensity: String, CaseIterable, Identifiable {
    case compact, comfortable, spacious

    var id: String { rawValue }
    var title: String { MoniLocalization.string(rawValue.capitalized) }

    var rowHeight: CGFloat {
        switch self {
        case .compact: 185
        case .comfortable: 205
        case .spacious: 225
        }
    }

    var spacing: CGFloat {
        switch self {
        case .compact: 10
        case .comfortable: 12
        case .spacious: 14
        }
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }
    var title: String { MoniLocalization.string(rawValue.capitalized) }
}

enum MenuBarMetric: String, CaseIterable, Identifiable {
    case cpu, memory, network, disk, battery, temperature

    var id: String { rawValue }

    var title: String {
        let key: String = switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .network: "Network"
        case .disk: "Disk"
        case .battery: "Battery"
        case .temperature: "Temp"
        }
        return MoniLocalization.string(key)
    }

    var symbol: String {
        switch self {
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .network: "arrow.down"
        case .disk: "internaldrive"
        case .battery: "battery.75percent"
        case .temperature: "thermometer.medium"
        }
    }
}

enum MenuBarDisplayStyle: String, CaseIterable, Identifiable {
    case valueOnly, graphOnly, graphAndValue

    var id: String { rawValue }

    var title: String {
        let key: String = switch self {
        case .valueOnly: "Value only"
        case .graphOnly: "Graph only"
        case .graphAndValue: "Graph + value"
        }
        return MoniLocalization.string(key)
    }
}
