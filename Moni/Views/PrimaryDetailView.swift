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
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.7)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.primary.opacity(0.05))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct HostDetailView: View {
    @EnvironmentObject private var monitor: SystemMonitor

    private var snapshot: SystemSnapshot { monitor.snapshot }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 12) {
                DetailPanel("Host") {
                    HStack(alignment: .top, spacing: 20) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(snapshot.host.name)
                                .font(.title2.bold())
                                .foregroundStyle(.cyan)
                            Text(snapshot.host.model)
                                .foregroundStyle(.secondary)
                            Text(snapshot.host.chip)
                                .fontWeight(.semibold)
                            Text(uptime(snapshot.host.uptime))
                                .font(.system(size: 38, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .moniNumericTransition(Int(snapshot.host.uptime))
                            Text("Uptime")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        gauges
                            .frame(width: 410)
                    }
                }

                HStack(alignment: .top, spacing: 12) {
                    DetailPanel("System information") {
                        valueGrid([
                            ("Model", snapshot.host.model),
                            ("Chip", snapshot.host.chip),
                            ("Memory", bytes(snapshot.memory.totalBytes)),
                            ("macOS", snapshot.host.operatingSystem),
                            ("Kernel", snapshot.host.kernel),
                            ("Logical CPUs", snapshot.host.processorCount.formatted()),
                            ("Processes", snapshot.processes.count.formatted()),
                            ("Volumes", snapshot.volumes.count.formatted())
                        ])
                    }
                    DetailPanel("Load averages") {
                        ForEach(Array(snapshot.host.loadAverages.enumerated()), id: \.offset) { index, load in
                            HStack {
                                Text(["1 min", "5 min", "15 min"][index])
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(String(format: "%.2f", load))
                                    .fontWeight(.bold)
                                    .monospacedDigit()
                            }
                        }
                    }
                    .frame(width: 250)
                }
            }
        }
    }

    private var gauges: some View {
        VStack(spacing: 14) {
            gauge("CPU", snapshot.cpu.total, .pink)
            gauge("Memory", snapshot.memory.usedPercent, .blue)
            gauge("Disk", snapshot.volumes.first?.usedPercent ?? 0, .orange)
        }
    }

    private func gauge(_ title: String, _ value: Double, _ color: Color) -> some View {
        VStack(spacing: 5) {
            HStack {
                Text(title)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(percent(value))
                    .fontWeight(.bold)
                    .monospacedDigit()
                    .moniNumericTransition(value)
            }
            ProgressView(value: min(100, value), total: 100)
                .tint(color)
                .moniAnimation(MoniMotion.data, value: value)
        }
    }

    private func valueGrid(_ values: [(String, String)]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
            ForEach(values, id: \.0) { key, value in
                VStack(alignment: .leading, spacing: 3) {
                    Text(key)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(value)
                        .fontWeight(.semibold)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct CPUDetailView: View {
    @EnvironmentObject private var monitor: SystemMonitor
    @Binding var selection: MonitorSection

    private var snapshot: SystemSnapshot { monitor.snapshot }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 12) {
                DetailPanel("CPU") {
                    HStack(alignment: .firstTextBaseline) {
                        Text(snapshot.host.chip)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(percent(snapshot.cpu.total))
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .moniNumericTransition(snapshot.cpu.total)
                    }
                    Sparkline(values: monitor.cpuHistory, color: .pink)
                        .frame(height: 155)
                    HStack {
                        MetricRow(label: "User", value: percent(snapshot.cpu.user), color: .pink)
                        MetricRow(label: "System", value: percent(snapshot.cpu.system), color: .orange)
                        MetricRow(label: "Idle", value: percent(snapshot.cpu.idle), color: .green)
                    }
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
                                        .tint(value > 80 ? .red : value > 45 ? .orange : .green)
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
                        detailValue("User", percent(snapshot.cpu.user))
                        detailValue("System", percent(snapshot.cpu.system))
                        detailValue("Idle", percent(snapshot.cpu.idle))
                        detailValue("Load (1m)", String(format: "%.2f", snapshot.host.loadAverages.first ?? 0))
                        detailValue("Logical CPUs", snapshot.host.processorCount.formatted())
                    }
                    .frame(width: 260)
                }

                DetailPanel("Top CPU consumers") {
                    processHeader(action: { selection = .processes })
                    ForEach(snapshot.processes.prefix(8)) { process in
                        processRow(process, metric: percent(process.cpuPercent), color: .pink)
                    }
                }
            }
        }
    }
}

private struct MemoryDetailView: View {
    @EnvironmentObject private var monitor: SystemMonitor
    @Binding var selection: MonitorSection

    private var snapshot: SystemSnapshot { monitor.snapshot }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 12) {
                DetailPanel("Memory") {
                    HStack(alignment: .firstTextBaseline) {
                        Text(bytes(snapshot.memory.totalBytes) + " unified memory")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(percent(snapshot.memory.usedPercent))
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .moniNumericTransition(snapshot.memory.usedPercent)
                    }
                    Sparkline(values: monitor.memoryHistory, color: .blue)
                        .frame(height: 155)
                }

                HStack(alignment: .top, spacing: 12) {
                    DetailPanel("Memory composition") {
                        memoryBar
                        detailValue("Used", bytes(snapshot.memory.usedBytes))
                        detailValue("Free", bytes(snapshot.memory.freeBytes))
                        detailValue("Cached", bytes(snapshot.memory.cachedBytes))
                        detailValue("Wired", bytes(snapshot.memory.wiredBytes))
                        detailValue("Compressed", bytes(snapshot.memory.compressedBytes))
                    }
                    DetailPanel("Memory pressure") {
                        Text(pressureLabel)
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundStyle(pressureColor)
                        ProgressView(value: snapshot.memory.usedPercent, total: 100)
                            .tint(pressureColor)
                            .moniAnimation(MoniMotion.data, value: snapshot.memory.usedPercent)
                        Text("Calculated from physical memory usage")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 300)
                }

                DetailPanel("Top memory consumers") {
                    processHeader(action: { selection = .processes })
                    ForEach(snapshot.processes.sorted { $0.memoryBytes > $1.memoryBytes }.prefix(8)) { process in
                        processRow(process, metric: bytes(process.memoryBytes), color: .blue)
                    }
                }
            }
        }
    }

    private var memoryBar: some View {
        GeometryReader { geometry in
            HStack(spacing: 2) {
                Rectangle().fill(Color.blue).frame(width: geometry.size.width * fraction(snapshot.memory.usedBytes))
                Rectangle().fill(Color.cyan).frame(width: geometry.size.width * fraction(snapshot.memory.cachedBytes))
                Rectangle().fill(Color.green)
            }
            .clipShape(Capsule())
            .moniAnimation(
                MoniMotion.data,
                value: [snapshot.memory.usedBytes, snapshot.memory.cachedBytes]
            )
        }
        .frame(height: 10)
    }

    private func fraction(_ value: UInt64) -> CGFloat {
        guard snapshot.memory.totalBytes > 0 else { return 0 }
        return CGFloat(Double(value) / Double(snapshot.memory.totalBytes))
    }

    private var pressureLabel: String {
        snapshot.memory.usedPercent > 85 ? "High" : snapshot.memory.usedPercent > 65 ? "Moderate" : "Normal"
    }

    private var pressureColor: Color {
        snapshot.memory.usedPercent > 85 ? .red : snapshot.memory.usedPercent > 65 ? .orange : .green
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
        VStack(spacing: 10) {
            HStack {
                TextField("Search name, path, or PID", text: $query)
                    .textFieldStyle(.roundedBorder)
                Picker("Sort", selection: $sort) {
                    ForEach(Sort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .frame(width: 155)
                Text("\(processes.count) processes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            DetailPanel("Processes") {
                HStack {
                    Text("Name").frame(maxWidth: .infinity, alignment: .leading)
                    Text("PID").frame(width: 64, alignment: .trailing)
                    Text("CPU").frame(width: 70, alignment: .trailing)
                    Text("Memory").frame(width: 90, alignment: .trailing)
                }
                .font(.caption.bold())
                .foregroundStyle(.secondary)

                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 2) {
                        ForEach(processes) { process in
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(process.name).fontWeight(.semibold).lineLimit(1)
                                    Text(process.path).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Text(process.pid.formatted()).frame(width: 64, alignment: .trailing)
                                Text(percent(process.cpuPercent)).frame(width: 70, alignment: .trailing)
                                Text(bytes(process.memoryBytes)).frame(width: 90, alignment: .trailing)
                            }
                            .font(.system(size: 12))
                            .monospacedDigit()
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color.primary.opacity(0.025))
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                        }
                    }
                }
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
            .foregroundStyle(.blue)
    }
    .font(.caption)
    .foregroundStyle(.secondary)
}

private func processRow(_ process: ProcessUsage, metric: String, color: Color) -> some View {
    HStack(spacing: 10) {
        VStack(alignment: .leading, spacing: 1) {
            Text(process.name).fontWeight(.semibold).lineLimit(1)
            Text("PID \(process.pid)").font(.caption2).foregroundStyle(.tertiary)
        }
        Spacer()
        Text(metric)
            .fontWeight(.bold)
            .foregroundStyle(color)
            .monospacedDigit()
            .moniNumericTransition(metric)
    }
    .font(.system(size: 12))
    .padding(.vertical, 3)
}

private func detailValue(_ key: String, _ value: String) -> some View {
    HStack {
        Text(key).foregroundStyle(.secondary)
        Spacer()
        Text(value)
            .fontWeight(.semibold)
            .monospacedDigit()
            .moniNumericTransition(value)
    }
    .font(.system(size: 12.5))
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
