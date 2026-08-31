import SwiftUI
import WidgetKit

struct MoniWidgetEntry: TimelineEntry {
    let date: Date
    let system: WidgetSystemSnapshot
    let isPlaceholder: Bool
    var isStale = false
}

struct MoniWidgetProvider: TimelineProvider {
    let kind: MoniWidgetKind

    func placeholder(in context: Context) -> MoniWidgetEntry {
        MoniWidgetEntry(date: .now, system: .placeholder, isPlaceholder: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (MoniWidgetEntry) -> Void) {
        completion(entry(isPreview: context.isPreview))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MoniWidgetEntry>) -> Void) {
        let entry = entry(isPreview: context.isPreview)
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(5 * 60))))
    }

    private func entry(isPreview: Bool) -> MoniWidgetEntry {
        guard !isPreview else {
            return MoniWidgetEntry(date: .now, system: .placeholder, isPlaceholder: false)
        }
        let now = Date()
        let system = MoniWidgetStorage.loadSystem()
        return MoniWidgetEntry(
            date: now,
            system: system ?? .placeholder,
            isPlaceholder: system == nil,
            isStale: system.map { now.timeIntervalSince($0.date) > kind.stalenessLimit } ?? false
        )
    }
}

enum MoniWidgetKind: String {
    case cpuSmall = "com.seaony.Moni.widget.cpu-small"
    case memorySmall = "com.seaony.Moni.widget.memory-small"
    case powerSmall = "com.seaony.Moni.widget.power-small"
    case storageSmall = "com.seaony.Moni.widget.storage-small"
    case wifiSmall = "com.seaony.Moni.widget.wifi-small"
    case processesSmall = "com.seaony.Moni.widget.processes-small"
    case dockerSmall = "com.seaony.Moni.widget.docker-small"
    case gpuSmall = "com.seaony.Moni.widget.gpu-small"
    case uptimeSmall = "com.seaony.Moni.widget.uptime-small"
    case networkMedium = "com.seaony.Moni.widget.network-medium"
    case topProcessesMedium = "com.seaony.Moni.widget.top-processes-medium"
    case sensorsMedium = "com.seaony.Moni.widget.sensors-medium"
    case memoryMedium = "com.seaony.Moni.widget.memory-medium"
    case diskActivityMedium = "com.seaony.Moni.widget.disk-activity-medium"
    case containersMedium = "com.seaony.Moni.widget.containers-medium"
    case alertsMedium = "com.seaony.Moni.widget.alerts-medium"
    case batteryHistoryMedium = "com.seaony.Moni.widget.battery-history-medium"
    case systemOverviewLarge = "com.seaony.Moni.widget.system-overview-large"
    case gpuThermalsLarge = "com.seaony.Moni.widget.gpu-thermals-large"
    case networkDetailLarge = "com.seaony.Moni.widget.network-detail-large"
    case activityMonitorLarge = "com.seaony.Moni.widget.activity-monitor-large"
    case storageBreakdownLarge = "com.seaony.Moni.widget.storage-breakdown-large"

    /// System metrics are written every 15s while Moni runs, so anything older
    /// means the numbers on screen are no longer live.
    var stalenessLimit: TimeInterval {
        10 * 60
    }
}

struct MoniWidgetView: View {
    let kind: MoniWidgetKind
    let entry: MoniWidgetEntry
    @AppStorage(
        MoniLocalization.preferenceKey,
        store: MoniLocalization.sharedDefaults
    ) private var appLanguage = AppLanguage.english.rawValue

    var body: some View {
        Group {
            switch kind {
            case .cpuSmall:
                CPUSmallWidgetView(snapshot: entry.system)
            case .memorySmall:
                MemorySmallWidgetView(snapshot: entry.system)
            case .powerSmall:
                PowerSmallWidgetView(snapshot: entry.system)
            case .storageSmall:
                StorageSmallWidgetView(snapshot: entry.system)
            case .wifiSmall:
                WiFiSmallWidgetView(snapshot: entry.system)
            case .processesSmall:
                ProcessesSmallWidgetView(snapshot: entry.system)
            case .dockerSmall:
                DockerSmallWidgetView(snapshot: entry.system)
            case .gpuSmall:
                GPUSmallWidgetView(snapshot: entry.system)
            case .uptimeSmall:
                UptimeSmallWidgetView(snapshot: entry.system)
            case .networkMedium:
                NetworkMediumWidgetView(snapshot: entry.system)
            case .topProcessesMedium:
                TopProcessesMediumWidgetView(snapshot: entry.system)
            case .sensorsMedium:
                SensorsMediumWidgetView(snapshot: entry.system)
            case .memoryMedium:
                MemoryMediumWidgetView(snapshot: entry.system)
            case .diskActivityMedium:
                DiskActivityMediumWidgetView(snapshot: entry.system)
            case .containersMedium:
                ContainersMediumWidgetView(snapshot: entry.system)
            case .alertsMedium:
                AlertsMediumWidgetView(snapshot: entry.system)
            case .batteryHistoryMedium:
                BatteryHistoryMediumWidgetView(snapshot: entry.system)
            case .systemOverviewLarge:
                SystemOverviewLargeWidgetView(snapshot: entry.system)
            case .gpuThermalsLarge:
                GPUThermalsLargeWidgetView(snapshot: entry.system)
            case .networkDetailLarge:
                NetworkDetailLargeWidgetView(snapshot: entry.system)
            case .activityMonitorLarge:
                ActivityMonitorLargeWidgetView(snapshot: entry.system)
            case .storageBreakdownLarge:
                StorageBreakdownLargeWidgetView(snapshot: entry.system)
            }
        }
        .environment(\.locale, selectedLanguage.locale)
    }

    private var selectedLanguage: AppLanguage {
        AppLanguage(rawValue: appLanguage) ?? .english
    }
}

func moniWidgetConfiguration(
    kind: MoniWidgetKind,
    displayName: String,
    description: String,
    family: WidgetFamily
) -> some WidgetConfiguration {
    StaticConfiguration(kind: kind.rawValue, provider: MoniWidgetProvider(kind: kind)) { entry in
        MoniWidgetView(kind: kind, entry: entry)
            .redacted(reason: entry.isPlaceholder ? .placeholder : [])
            .overlay(alignment: .topTrailing) {
                if entry.isStale {
                    Circle()
                        .fill(WidgetTheme.orange)
                        .frame(width: 6, height: 6)
                        .padding(5)
                        .accessibilityLabel("Data is not live")
                }
            }
            .containerBackground(for: .widget) {
                Color(nsColor: .windowBackgroundColor)
            }
    }
    .configurationDisplayName(MoniLocalization.string(displayName))
    .description(MoniLocalization.string(description))
    .supportedFamilies([family])
    .contentMarginsDisabled()
}
