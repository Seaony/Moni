import SwiftUI
import WidgetKit

struct MoniWidgetEntry: TimelineEntry {
    let date: Date
    let system: WidgetSystemSnapshot
    let ai: WidgetAISnapshot
}

struct MoniWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> MoniWidgetEntry {
        MoniWidgetEntry(date: .now, system: .placeholder, ai: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (MoniWidgetEntry) -> Void) {
        completion(entry(isPreview: context.isPreview))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MoniWidgetEntry>) -> Void) {
        let entry = entry(isPreview: context.isPreview)
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(5 * 60))))
    }

    private func entry(isPreview: Bool) -> MoniWidgetEntry {
        MoniWidgetEntry(
            date: .now,
            system: isPreview ? .placeholder : MoniWidgetStorage.loadSystem() ?? .placeholder,
            ai: isPreview ? .placeholder : MoniWidgetStorage.loadAI() ?? .placeholder
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
    case aiSpendSmall = "com.seaony.Moni.widget.ai-spend-small"
}

struct MoniWidgetView: View {
    let kind: MoniWidgetKind
    let entry: MoniWidgetEntry

    var body: some View {
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
        case .aiSpendSmall:
            AISpendSmallWidgetView(snapshot: entry.ai)
        }
    }
}

func moniWidgetConfiguration(
    kind: MoniWidgetKind,
    displayName: String,
    description: String,
    family: WidgetFamily
) -> some WidgetConfiguration {
    StaticConfiguration(kind: kind.rawValue, provider: MoniWidgetProvider()) { entry in
        MoniWidgetView(kind: kind, entry: entry)
            .containerBackground(for: .widget) {
                Color(nsColor: .windowBackgroundColor)
            }
    }
    .configurationDisplayName(displayName)
    .description(description)
    .supportedFamilies([family])
    .contentMarginsDisabled()
}
