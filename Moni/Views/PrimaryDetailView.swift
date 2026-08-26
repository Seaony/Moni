import SwiftUI

struct PrimaryDetailView: View {
    let section: MonitorSection
    @Binding var selection: MonitorSection

    var body: some View {
        switch section {
        case .host:
            HostDetailView()
        case .cpu:
            CPUDetailView(selection: $selection)
        case .memory:
            MemoryDetailView(selection: $selection)
        case .processes:
            ProcessesDetailView()
        default:
            EmptyView()
        }
    }
}

struct DetailPanel<Content: View>: View {
    let title: String?
    @ViewBuilder let content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.7)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(MoniPalette.card)
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(MoniPalette.line, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct HostDetailView: View {
    @EnvironmentObject private var monitor: SystemMonitor
    @State private var historyRange = "1m"

    private var snapshot: SystemSnapshot { monitor.snapshot }
    private var rootVolume: VolumeUsage? { snapshot.volumes.first { $0.mountPath == "/" } }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 12) {
                DetailPanel {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(snapshot.host.name)
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(MoniPalette.blue)
                        Text("\(snapshot.host.model) · \(snapshot.host.kernel)")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                        Spacer(minLength: 12)
                        HistoryRangePicker(selection: $historyRange)
                        Text(uptime(snapshot.host.uptime))
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .moniNumericTransition(Int(snapshot.host.uptime))
                    }

                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3),
                        spacing: 12
                    ) {
                        ForEach(hostStatistics, id: \.0) { key, value in
                            HStack(spacing: 8) {
                                Text(key)
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: 6)
                                Text(value)
                                    .fontWeight(.bold)
                                    .monospacedDigit()
                                    .lineLimit(1)
                            }
                            .font(.system(size: 12.5))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 13)
                            .background(MoniPalette.inset)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }
                }

                DetailPanel("Load average") {
                    HStack(spacing: 26) {
                        ForEach(Array(snapshot.host.loadAverages.enumerated()), id: \.offset) { index, load in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(["1 min", "5 min", "15 min"][index])
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(.secondary)
                                Text(String(format: "%.2f", load))
                                    .font(.system(size: 26, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                                    .moniNumericTransition(load)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    Sparkline(
                        values: Array(monitor.cpuHistory.suffix(historySampleCount(historyRange))),
                        color: .secondary,
                        showsFill: false,
                        lineWidth: 1.8
                    )
                    .frame(height: 110)
                }
            }
        }
    }

    private var hostStatistics: [(String, String)] {
        [
            ("Model", snapshot.host.model),
            ("Chip", snapshot.host.chip),
            ("Memory", bytes(snapshot.memory.totalBytes)),
            ("macOS", snapshot.host.operatingSystem),
            ("Kernel", snapshot.host.kernel),
            ("Logical CPUs", snapshot.host.processorCount.formatted()),
            ("Boot volume", rootVolume?.name ?? "—"),
            ("Processes", snapshot.processes.count.formatted()),
            ("Volumes", snapshot.volumes.count.formatted())
        ]
    }

}

private struct CPUDetailView: View {
    @EnvironmentObject private var monitor: SystemMonitor
    @Binding var selection: MonitorSection
    @State private var historyRange = "1m"

    private var snapshot: SystemSnapshot { monitor.snapshot }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 12) {
                DetailPanel {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("CPU")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(MoniPalette.pink)
                        Text("\(snapshot.host.chip) · \(snapshot.cpu.perCore.count) cores")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.tertiary)
                        Spacer(minLength: 12)
                        HistoryRangePicker(selection: $historyRange)
                        Text(percent(snapshot.cpu.total))
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .moniNumericTransition(snapshot.cpu.total)
                    }
                    Sparkline(
                        values: Array(monitor.cpuHistory.suffix(historySampleCount(historyRange))),
                        color: MoniPalette.pink
                    )
                    .frame(height: 160)
                    HStack {
                        Text(historyRange == "1m" ? "-1 min" : historyRange == "1h" ? "-1 hour" : "-24 hours")
                        Spacer()
                        Text("now")
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(.quaternary)
                }

                HStack(alignment: .top, spacing: 12) {
                    DetailPanel("Per-core load") {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 9) {
                            ForEach(Array(snapshot.cpu.perCore.enumerated()), id: \.offset) { index, value in
                                HStack(spacing: 8) {
                                    Text("Core \(index + 1)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 48, alignment: .leading)
                                    ProgressView(value: value, total: 100)
                                        .tint(value > 80 ? MoniPalette.red : value > 45 ? MoniPalette.orange : MoniPalette.green)
                                        .moniAnimation(MoniMotion.data, value: value)
                                    Text(percent(value))
                                        .font(.caption.bold())
                                        .monospacedDigit()
                                        .frame(width: 34, alignment: .trailing)
                                        .moniNumericTransition(value)
                                }
                            }
                        }
                    }
                    DetailPanel("Breakdown") {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                            detailStat("User", percent(snapshot.cpu.user))
                            detailStat("System", percent(snapshot.cpu.system))
                            detailStat("Idle", percent(snapshot.cpu.idle))
                            detailStat("Nice", percent(snapshot.cpu.nice))
                            detailStat("Load (1m)", String(format: "%.2f", snapshot.host.loadAverages.first ?? 0))
                        }
                    }
                    .frame(width: 390)
                }

                DetailPanel("Top CPU consumers") {
                    processHeader(action: { selection = .processes })
                    let maximum = max(1, snapshot.processes.prefix(6).map(\.cpuPercent).max() ?? 1)
                    ForEach(snapshot.processes.prefix(6)) { process in
                        consumerRow(
                            process,
                            value: process.cpuPercent,
                            maximum: maximum,
                            metric: percent(process.cpuPercent),
                            color: MoniPalette.pink,
                            metricWidth: 60
                        )
                    }
                }
            }
        }
    }
}

private struct MemoryDetailView: View {
    @EnvironmentObject private var monitor: SystemMonitor
    @Binding var selection: MonitorSection
    @State private var historyRange = "1m"

    private var snapshot: SystemSnapshot { monitor.snapshot }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 12) {
                DetailPanel {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("Memory")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(MoniPalette.blue)
                        Text(bytes(snapshot.memory.totalBytes) + " unified memory")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.tertiary)
                        Spacer(minLength: 12)
                        HistoryRangePicker(selection: $historyRange)
                        Text(percent(snapshot.memory.usedPercent))
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .moniNumericTransition(snapshot.memory.usedPercent)
                    }
                    Sparkline(
                        values: Array(monitor.memoryHistory.suffix(historySampleCount(historyRange))),
                        color: MoniPalette.blue
                    )
                    .frame(height: 160)
                    HStack {
                        Text(historyRange == "1m" ? "-1 min" : historyRange == "1h" ? "-1 hour" : "-24 hours")
                        Spacer()
                        Text("now")
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(.quaternary)
                }

                HStack(alignment: .top, spacing: 12) {
                    DetailPanel("Memory pressure") {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(percent(snapshot.memory.usedPercent))
                                .font(.system(size: 30, weight: .bold, design: .rounded))
                                .foregroundStyle(pressureColor)
                                .moniNumericTransition(snapshot.memory.usedPercent)
                            Text(pressureLabel)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(pressureColor)
                        }
                        ProgressView(value: snapshot.memory.usedPercent, total: 100)
                            .tint(pressureColor)
                            .moniAnimation(MoniMotion.data, value: snapshot.memory.usedPercent)
                        memoryBar
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                            memoryLegend("App", appMemoryBytes, MoniPalette.blue)
                            memoryLegend("Wired", snapshot.memory.wiredBytes, MoniPalette.purple)
                            memoryLegend("Compressed", snapshot.memory.compressedBytes, MoniPalette.orange)
                            memoryLegend("Cached", snapshot.memory.cachedBytes, MoniPalette.cyan)
                        }
                    }
                    DetailPanel("VM statistics") {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                            detailStat("Used", bytes(snapshot.memory.usedBytes))
                            detailStat("Free", bytes(snapshot.memory.freeBytes))
                            detailStat("Cached files", bytes(snapshot.memory.cachedBytes))
                            detailStat("Swap used", bytes(snapshot.memory.swapUsedBytes))
                            detailStat("Page ins", snapshot.memory.pageIns.formatted())
                            detailStat("Page outs", snapshot.memory.pageOuts.formatted())
                            detailStat("Compressor", bytes(snapshot.memory.compressedBytes))
                            detailStat("Faults", snapshot.memory.faults.formatted())
                        }
                    }
                }

                DetailPanel("Top memory consumers") {
                    processHeader(action: { selection = .processes })
                    let consumers = Array(snapshot.processes.sorted { $0.memoryBytes > $1.memoryBytes }.prefix(6))
                    let maximum = max(UInt64(1), consumers.map(\.memoryBytes).max() ?? 1)
                    ForEach(consumers) { process in
                        consumerRow(
                            process,
                            value: Double(process.memoryBytes),
                            maximum: Double(maximum),
                            metric: bytes(process.memoryBytes),
                            color: MoniPalette.blue,
                            metricWidth: 76
                        )
                    }
                }
            }
        }
    }

    private var memoryBar: some View {
        GeometryReader { geometry in
            HStack(spacing: 2) {
                Rectangle().fill(MoniPalette.blue).frame(width: geometry.size.width * fraction(appMemoryBytes))
                Rectangle().fill(MoniPalette.purple).frame(width: geometry.size.width * fraction(snapshot.memory.wiredBytes))
                Rectangle().fill(MoniPalette.orange).frame(width: geometry.size.width * fraction(snapshot.memory.compressedBytes))
                Rectangle().fill(MoniPalette.cyan).frame(width: geometry.size.width * fraction(snapshot.memory.cachedBytes))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .moniAnimation(
                MoniMotion.data,
                value: [
                    appMemoryBytes,
                    snapshot.memory.wiredBytes,
                    snapshot.memory.compressedBytes,
                    snapshot.memory.cachedBytes
                ]
            )
        }
        .frame(height: 10)
    }

    private var appMemoryBytes: UInt64 {
        snapshot.memory.usedBytes
            .subtractingClamped(snapshot.memory.wiredBytes)
            .subtractingClamped(snapshot.memory.compressedBytes)
    }

    private func fraction(_ value: UInt64) -> CGFloat {
        guard snapshot.memory.totalBytes > 0 else { return 0 }
        return CGFloat(Double(value) / Double(snapshot.memory.totalBytes))
    }

    private var pressureLabel: String {
        snapshot.memory.usedPercent > 85 ? "High" : snapshot.memory.usedPercent > 65 ? "Moderate" : "Normal"
    }

    private var pressureColor: Color {
        snapshot.memory.usedPercent > 85
            ? MoniPalette.red
            : snapshot.memory.usedPercent > 65 ? MoniPalette.orange : MoniPalette.green
    }

    private func memoryLegend(_ title: String, _ value: UInt64, _ color: Color) -> some View {
        MetricRow(label: title, value: bytes(value), color: color)
    }
}

private struct ProcessesDetailView: View {
    enum Sort: String, CaseIterable {
        case cpu = "CPU"
        case memory = "Memory"
        case name = "Name"
    }

    @EnvironmentObject private var monitor: SystemMonitor
    @State private var query = ""
    @State private var sort: Sort = .cpu

    private var processes: [ProcessUsage] {
        let filtered = monitor.snapshot.processes.filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.path.localizedCaseInsensitiveContains(query) || String($0.pid).contains(query)
        }
        switch sort {
        case .cpu: return filtered.sorted { $0.cpuPercent > $1.cpuPercent }
        case .memory: return filtered.sorted { $0.memoryBytes > $1.memoryBytes }
        case .name: return filtered.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    var body: some View {
        DetailPanel {
            HStack(spacing: 10) {
                Text("Processes")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(MoniPalette.purple)
                Text("\(processes.count) matches")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.tertiary)
                    .moniNumericTransition(processes.count)
                Spacer()
                TextField("Search processes", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
            }

            HStack(spacing: 10) {
                sortHeader("Process", value: .name)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("PID").frame(width: 70, alignment: .trailing)
                sortHeader("CPU", value: .cpu).frame(width: 90, alignment: .trailing)
                sortHeader("Memory", value: .memory).frame(width: 90, alignment: .trailing)
                Text("Threads").frame(width: 80, alignment: .trailing)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 2) {
                    ForEach(processes) { process in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(process.name).fontWeight(.semibold).lineLimit(1)
                                Text(process.path).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Text(process.pid.formatted()).frame(width: 70, alignment: .trailing)
                            Text(percent(process.cpuPercent)).frame(width: 90, alignment: .trailing)
                            Text(bytes(process.memoryBytes)).frame(width: 90, alignment: .trailing)
                            Text(process.threadCount.formatted()).frame(width: 80, alignment: .trailing)
                        }
                        .font(.system(size: 12.5))
                        .monospacedDigit()
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(MoniPalette.card)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
            }
            .frame(maxHeight: 604)
        }
    }

    private func sortHeader(_ title: String, value: Sort) -> some View {
        Button {
            sort = value
        } label: {
            Text(title + (sort == value ? " ↓" : ""))
                .frame(maxWidth: .infinity, alignment: value == .name ? .leading : .trailing)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .moniPointingHand()
    }
}

private struct HistoryRangePicker: View {
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 4) {
            ForEach(["1m", "1h", "24h"], id: \.self) { range in
                Button(range) {
                    selection = range
                }
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(selection == range ? .primary : .tertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(selection == range ? MoniPalette.controlSelected : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .buttonStyle(MoniPressButtonStyle(scale: 0.98))
            }
        }
    }
}

private func processHeader(action: @escaping () -> Void) -> some View {
    HStack {
        Text("Name")
        Spacer()
        Button("All processes ›", action: action)
            .buttonStyle(MoniPressButtonStyle())
            .foregroundStyle(MoniPalette.blue)
    }
    .font(.caption)
    .foregroundStyle(.secondary)
}

private func consumerRow(
    _ process: ProcessUsage,
    value: Double,
    maximum: Double,
    metric: String,
    color: Color,
    metricWidth: CGFloat
) -> some View {
    HStack(spacing: 10) {
        Text(process.name)
            .fontWeight(.semibold)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
        Text(process.pid.formatted())
            .foregroundStyle(.tertiary)
            .frame(width: 72, alignment: .leading)
        ProgressView(value: value, total: maximum)
            .tint(color)
            .frame(width: 130)
        Text(metric)
            .fontWeight(.bold)
            .monospacedDigit()
            .frame(width: metricWidth, alignment: .trailing)
            .moniNumericTransition(metric)
    }
    .font(.system(size: 13))
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
}

private func detailStat(_ key: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
        Text(key)
            .foregroundStyle(.secondary)
        Text(value)
            .fontWeight(.bold)
            .monospacedDigit()
    }
    .font(.system(size: 12.5))
    .frame(maxWidth: .infinity, alignment: .leading)
}

private func historySampleCount(_ range: String) -> Int {
    switch range {
    case "1h": 3_600
    case "24h": 86_400
    default: 60
    }
}

private func percent(_ value: Double) -> String {
    "\(Int(value.rounded()))%"
}

private func bytes(_ value: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
}

private func uptime(_ interval: TimeInterval) -> String {
    let days = Int(interval) / 86_400
    let hours = (Int(interval) % 86_400) / 3_600
    let minutes = (Int(interval) % 3_600) / 60
    return "\(days)d \(hours)h \(minutes)m"
}

private extension UInt64 {
    func subtractingClamped(_ value: UInt64) -> UInt64 {
        self >= value ? self - value : 0
    }
}
