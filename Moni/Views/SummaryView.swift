import SwiftUI

struct SummaryView: View {
    @EnvironmentObject private var monitor: SystemMonitor
    @Binding var selection: MonitorSection

    private var snapshot: SystemSnapshot { monitor.snapshot }
    private var rootVolume: VolumeUsage? { snapshot.volumes.first { $0.mountPath == "/" } }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                hostCard
                cpuCard
                memoryCard
                gpuCard
                networkCard
                storageCard
                processCard
                powerCard
            }
        }
        .scrollIndicators(.visible)
    }

    private var hostCard: some View {
        cardButton(.host) {
            MetricCard(title: snapshot.host.name, symbol: "server.rack", color: .cyan) {
                Text(snapshot.host.model)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(formatUptime(snapshot.host.uptime))
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("Uptime")
                    .foregroundStyle(.secondary)
                MetricRow(label: "Load", value: snapshot.host.loadAverages.map { String(format: "%.2f", $0) }.joined(separator: " · "), color: .orange)
                MetricRow(label: "Processes", value: snapshot.processes.count.formatted(), color: .purple)
            }
        }
    }

    private var cpuCard: some View {
        cardButton(.cpu) {
            MetricCard(title: "CPU", symbol: "cpu", color: .pink, trailing: "\(snapshot.host.processorCount) cores") {
                HStack(alignment: .bottom, spacing: 12) {
                    Text(percent(snapshot.cpu.total))
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Sparkline(values: monitor.cpuHistory, color: .pink)
                        .frame(height: 66)
                }
                MetricRow(label: "User", value: percent(snapshot.cpu.user), color: .pink)
                MetricRow(label: "System", value: percent(snapshot.cpu.system), color: .orange)
                MetricRow(label: "Idle", value: percent(snapshot.cpu.idle), color: .green)
            }
        }
    }

    private var memoryCard: some View {
        cardButton(.memory) {
            MetricCard(title: "Memory", symbol: "memorychip", color: .blue, trailing: "Live") {
                HStack(alignment: .bottom, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(percent(snapshot.memory.usedPercent))
                            .font(.system(size: 36, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        Text("\(bytes(snapshot.memory.usedBytes)) / \(bytes(snapshot.memory.totalBytes))")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Sparkline(values: monitor.memoryHistory, color: .blue)
                        .frame(height: 66)
                }
                MetricRow(label: "Free", value: bytes(snapshot.memory.freeBytes), color: .green)
                MetricRow(label: "Cached", value: bytes(snapshot.memory.cachedBytes), color: .cyan)
                MetricRow(label: "Wired", value: bytes(snapshot.memory.wiredBytes), color: .orange)
            }
        }
    }

    private var gpuCard: some View {
        cardButton(.gpu) {
            MetricCard(title: "GPU", symbol: "display", color: .green, trailing: "1 device") {
                Text("Utilization")
                    .foregroundStyle(.secondary)
                Text("No Data")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text(snapshot.host.chip)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("macOS does not expose GPU utilization through a public API")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var networkCard: some View {
        cardButton(.network) {
            MetricCard(title: "Network", symbol: "arrow.up.arrow.down", color: .cyan, trailing: "Live") {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("↓ \(rate(snapshot.network.downloadBytesPerSecond))")
                            .foregroundStyle(.cyan)
                        Text("↑ \(rate(snapshot.network.uploadBytesPerSecond))")
                            .foregroundStyle(.orange)
                    }
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    Sparkline(values: monitor.downloadHistory, color: .cyan)
                        .frame(height: 72)
                }
                MetricRow(label: "Received", value: bytes(snapshot.network.totalReceivedBytes), color: .cyan)
                MetricRow(label: "Sent", value: bytes(snapshot.network.totalSentBytes), color: .orange)
                MetricRow(label: "Active", value: "\(snapshot.network.interfaces.filter(\.isActive).count) interfaces", color: .green)
            }
        }
    }

    private var storageCard: some View {
        cardButton(.storage) {
            MetricCard(title: "Storage", symbol: "internaldrive", color: .orange, trailing: "\(snapshot.volumes.count) volumes") {
                if let volume = rootVolume {
                    HStack {
                        Text(volume.mountPath)
                            .fontWeight(.semibold)
                        Spacer()
                        Text(percent(volume.usedPercent))
                            .fontWeight(.bold)
                            .foregroundStyle(volume.usedPercent >= 90 ? .red : .green)
                    }
                    ProgressView(value: volume.usedPercent, total: 100)
                        .tint(volume.usedPercent >= 90 ? .red : .orange)
                    Text("\(bytes(UInt64(volume.usedBytes))) / \(bytes(UInt64(volume.totalBytes))) used")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    MetricRow(label: "Available", value: bytes(UInt64(max(0, volume.availableBytes))), color: .green)
                } else {
                    Text("No mounted volumes")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var processCard: some View {
        cardButton(.processes) {
            MetricCard(title: "Processes", symbol: "list.bullet.rectangle", color: .purple, trailing: snapshot.processes.count.formatted()) {
                ForEach(snapshot.processes.prefix(4)) { process in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(process.name)
                                .lineLimit(1)
                                .fontWeight(.semibold)
                            Text("PID \(process.pid)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Text(percent(process.cpuPercent))
                            .monospacedDigit()
                        Text(bytes(process.memoryBytes))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: 11.5))
                }
            }
        }
    }

    private var powerCard: some View {
        cardButton(.sensors) {
            MetricCard(title: "Power & Sensors", symbol: "battery.75percent", color: .yellow, trailing: snapshot.power.isCharging ? "Charging" : nil) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Battery")
                            .foregroundStyle(.secondary)
                        Text(snapshot.power.batteryPercent.map(percent) ?? "No Battery")
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                    }
                    Spacer()
                    VStack(alignment: .leading, spacing: 3) {
                        Text("CPU die")
                            .foregroundStyle(.secondary)
                        Text("No Data")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                    }
                }
                Spacer()
                MetricRow(
                    label: snapshot.power.isCharging ? "Power source" : "Time remaining",
                    value: powerDetail,
                    color: snapshot.power.isCharging ? .green : .yellow
                )
                Text("Temperature sensors require non-public hardware access")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var powerDetail: String {
        if snapshot.power.isCharging { return "AC Power" }
        if snapshot.power.batteryPercent ?? 0 >= 100 { return "Fully charged" }
        guard let minutes = snapshot.power.timeRemainingMinutes else { return "Calculating" }
        guard minutes > 0 else { return "Calculating" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    private func cardButton<Content: View>(_ target: MonitorSection, @ViewBuilder content: () -> Content) -> some View {
        Button {
            selection = target
        } label: {
            content()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    private func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
    }

    private func rate(_ value: Double) -> String {
        "\(ByteCountFormatter.string(fromByteCount: Int64(max(0, value)), countStyle: .decimal))/s"
    }

    private func formatUptime(_ interval: TimeInterval) -> String {
        let days = Int(interval) / 86_400
        let hours = (Int(interval) % 86_400) / 3_600
        return "\(days)d \(hours)h"
    }
}
