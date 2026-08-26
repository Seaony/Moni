import SwiftUI
import WidgetKit

struct SystemOverviewLargeWidget: Widget {
    var body: some WidgetConfiguration {
        moniWidgetConfiguration(
            kind: .systemOverviewLarge,
            displayName: "System Overview",
            description: "集中查看 CPU、内存、网络、存储与高占用进程。",
            family: .systemLarge
        )
    }
}

struct SystemOverviewLargeWidgetView: View {
    let snapshot: WidgetSystemSnapshot

    private var stats: [(String, String, Double, Color)] {
        [
            ("CPU", "\(Int(snapshot.cpu.total.rounded()))%", snapshot.cpu.total, WidgetTheme.pink),
            ("Memory", "\(Int(snapshot.memory.usedPercent.rounded()))%", snapshot.memory.usedPercent, WidgetTheme.blue),
            ("Network", ByteCountFormatter.string(fromByteCount: Int64(snapshot.network.downloadBytesPerSecond), countStyle: .decimal) + "/s", min(100, snapshot.network.downloadBytesPerSecond / 50_000), WidgetTheme.cyan),
            ("Storage", "\(Int((snapshot.volume?.usedPercent ?? 0).rounded()))%", snapshot.volume?.usedPercent ?? 0, WidgetTheme.orange)
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WidgetHeader(title: snapshot.hostName, symbol: "server.rack", color: WidgetTheme.blue, trailing: "up \(uptime)")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(Array(stats.enumerated()), id: \.offset) { _, stat in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 5) {
                            Circle().fill(stat.3).frame(width: 6, height: 6)
                            Text(stat.0).foregroundStyle(WidgetTheme.secondary)
                        }
                        .font(.system(size: 10))
                        Text(stat.1)
                            .font(.system(size: 18, weight: .heavy, design: .rounded))
                            .monospacedDigit()
                            .minimumScaleFactor(0.65)
                            .lineLimit(1)
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Capsule().fill(WidgetTheme.track)
                                Capsule().fill(stat.3).frame(width: geometry.size.width * min(1, max(0, stat.2 / 100)))
                            }
                        }
                        .frame(height: 4)
                    }
                    .padding(9)
                    .background(WidgetTheme.inset, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(.top, 10)
            Text("CPU · LAST 60s")
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(WidgetTheme.secondary)
                .padding(.top, 10)
            WidgetLineChart(values: snapshot.histories.cpu, color: WidgetTheme.pink)
                .frame(height: 55)
                .padding(.top, 4)
            Spacer(minLength: 8)
            VStack(spacing: 7) {
                ForEach(Array(snapshot.processes.prefix(3).enumerated()), id: \.offset) { _, process in
                    HStack(spacing: 8) {
                        Text(process.name).fontWeight(.semibold).lineLimit(1).frame(width: 100, alignment: .leading)
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Capsule().fill(WidgetTheme.track)
                                Capsule().fill(WidgetTheme.pink).frame(width: geometry.size.width * min(1, process.cpuPercent / 100))
                            }
                        }
                        .frame(height: 4)
                        Text("\(Int(process.cpuPercent.rounded()))%")
                            .fontWeight(.bold)
                            .monospacedDigit()
                            .frame(width: 34, alignment: .trailing)
                    }
                    .font(.system(size: 10.5))
                }
            }
        }
        .padding(18)
    }

    private var uptime: String {
        let days = Int(snapshot.uptime) / 86_400
        let hours = (Int(snapshot.uptime) % 86_400) / 3_600
        return "\(days)d \(hours)h"
    }
}

struct AIUsageLargeWidget: Widget {
    var body: some WidgetConfiguration {
        moniWidgetConfiguration(
            kind: .aiUsageLarge,
            displayName: "AI Usage Details",
            description: "查看 AI 总用量、成本趋势和各服务额度。",
            family: .systemLarge
        )
    }
}

struct AIUsageLargeWidgetView: View {
    let snapshot: WidgetAISnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WidgetHeader(title: "AI Usage", symbol: "sparkles", color: WidgetTheme.indigo, trailing: "This month · \(snapshot.providers.count) accounts")
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(snapshot.estimatedCostUSD?.formatted(.currency(code: "USD").precision(.fractionLength(0))) ?? "—")
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                Text(compact(snapshot.totalTokens) + " tokens")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(WidgetTheme.secondary)
            }
            .padding(.top, 10)
            WidgetLineChart(values: snapshot.daily.map { $0.costUSD }, color: WidgetTheme.indigo)
                .frame(height: 74)
                .padding(.top, 8)
            Spacer(minLength: 8)
            VStack(spacing: 7) {
                ForEach(Array(snapshot.providers.prefix(4).enumerated()), id: \.offset) { index, provider in
                    providerCard(provider, color: providerColor(index))
                }
            }
        }
        .padding(18)
    }

    private func providerCard(_ provider: WidgetAIProvider, color: Color) -> some View {
        let quota = provider.quotas.first
        return VStack(spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(provider.name == "Claude" ? "Claude Code" : provider.name)
                    .fontWeight(.bold)
                if let plan = provider.plan {
                    Text(plan).foregroundStyle(WidgetTheme.tertiary)
                }
                Spacer(minLength: 4)
                Text(compact(provider.totalTokens))
                    .foregroundStyle(WidgetTheme.secondary)
                Text(provider.estimatedCostUSD?.formatted(.currency(code: "USD")) ?? "—")
                    .fontWeight(.semibold)
            }
            .font(.system(size: 10))
            HStack(spacing: 7) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(WidgetTheme.track)
                        Capsule().fill(color).frame(width: geometry.size.width * min(1, max(0, (quota?.remainingPercent ?? 0) / 100)))
                    }
                }
                .frame(height: 4)
                Text(quota.map { "\(Int($0.remainingPercent.rounded()))% left" } ?? "No quota")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(quota == nil ? WidgetTheme.tertiary : color)
                    .frame(width: 56, alignment: .trailing)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(WidgetTheme.inset, in: RoundedRectangle(cornerRadius: 11))
    }

    private func compact(_ value: UInt64) -> String {
        value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }

    private func providerColor(_ index: Int) -> Color {
        [WidgetTheme.orange, WidgetTheme.cyan, WidgetTheme.blue, WidgetTheme.purple][index % 4]
    }
}

struct GPUThermalsLargeWidget: Widget {
    var body: some WidgetConfiguration {
        moniWidgetConfiguration(
            kind: .gpuThermalsLarge,
            displayName: "GPU & Thermals",
            description: "查看 GPU 引擎负载、趋势、功耗与温度。",
            family: .systemLarge
        )
    }
}

struct GPUThermalsLargeWidgetView: View {
    let snapshot: WidgetSystemSnapshot

    private var engines: [(String, Double?)] {
        [
            ("Overall", snapshot.gpu.utilizationPercent),
            ("Renderer", snapshot.gpu.rendererPercent),
            ("Tiler", snapshot.gpu.tilerPercent),
            ("Memory", memoryPercent)
        ]
    }

    private var memoryPercent: Double? {
        guard let used = snapshot.gpu.allocatedMemoryBytes, snapshot.memory.totalBytes > 0 else { return nil }
        return Double(used) / Double(snapshot.memory.totalBytes) * 100
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WidgetHeader(title: "GPU & Thermals", symbol: "display", color: WidgetTheme.green, trailing: snapshot.gpu.name)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(snapshot.gpu.utilizationPercent.map { "\(Int($0.rounded()))%" } ?? "—")
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                Text(snapshot.gpu.powerWatts.map { String(format: "utilization · %.1f W", $0) } ?? "utilization")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(WidgetTheme.secondary)
            }
            .padding(.top, 10)
            WidgetLineChart(values: snapshot.histories.gpu, color: WidgetTheme.green)
                .frame(height: 70)
                .padding(.top, 7)
            VStack(spacing: 7) {
                ForEach(Array(engines.enumerated()), id: \.offset) { _, engine in
                    HStack(spacing: 8) {
                        Text(engine.0).foregroundStyle(WidgetTheme.secondary).frame(width: 62, alignment: .leading)
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Capsule().fill(WidgetTheme.track)
                                Capsule().fill(WidgetTheme.green).frame(width: geometry.size.width * min(1, max(0, (engine.1 ?? 0) / 100)))
                            }
                        }
                        .frame(height: 4)
                        Text(engine.1.map { "\(Int($0.rounded()))%" } ?? "—")
                            .fontWeight(.bold)
                            .monospacedDigit()
                            .frame(width: 34, alignment: .trailing)
                    }
                    .font(.system(size: 10))
                }
            }
            .padding(.top, 10)
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                thermalTile("CPU", snapshot.power.cpuTemperatureCelsius)
                thermalTile("GPU", snapshot.power.gpuTemperatureCelsius)
                thermalTile("Battery", snapshot.power.batteryTemperatureCelsius)
            }
        }
        .padding(18)
    }

    private func thermalTile(_ label: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).foregroundStyle(WidgetTheme.tertiary)
            Text(value.map { "\(Int($0.rounded()))°" } ?? "—")
                .font(.system(size: 17, weight: .heavy, design: .rounded))
                .monospacedDigit()
        }
        .font(.system(size: 9.5))
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WidgetTheme.inset, in: RoundedRectangle(cornerRadius: 11))
    }
}

struct NetworkDetailLargeWidget: Widget {
    var body: some WidgetConfiguration {
        moniWidgetConfiguration(
            kind: .networkDetailLarge,
            displayName: "Network Detail",
            description: "查看网络速率趋势、接口、延迟与公网地址。",
            family: .systemLarge
        )
    }
}

struct NetworkDetailLargeWidgetView: View {
    let snapshot: WidgetSystemSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WidgetHeader(title: "Network Detail", symbol: "arrow.up.arrow.down", color: WidgetTheme.cyan, trailing: snapshot.network.publicIPAddress)
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text("↓ " + rate(snapshot.network.downloadBytesPerSecond)).foregroundStyle(WidgetTheme.cyan)
                Text("↑ " + rate(snapshot.network.uploadBytesPerSecond)).foregroundStyle(WidgetTheme.orange)
            }
            .font(.system(size: 24, weight: .heavy, design: .rounded))
            .monospacedDigit()
            .padding(.top, 10)
            ZStack {
                WidgetLineChart(values: snapshot.histories.download, color: WidgetTheme.cyan)
                WidgetLineChart(values: snapshot.histories.upload, color: WidgetTheme.orange, showsFill: false)
            }
            .frame(height: 76)
            .padding(.top, 7)
            VStack(spacing: 7) {
                ForEach(Array(snapshot.network.interfaces.prefix(4).enumerated()), id: \.offset) { _, interface in
                    HStack(spacing: 8) {
                        Text(interface.name).fontWeight(.bold).frame(width: 40, alignment: .leading)
                        Text([interface.kind, interface.address].compactMap { $0 }.joined(separator: " · "))
                            .foregroundStyle(WidgetTheme.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(interface.isActive ? "Active" : "Inactive")
                            .fontWeight(.bold)
                            .foregroundStyle(interface.isActive ? WidgetTheme.green : WidgetTheme.tertiary)
                    }
                    .font(.system(size: 10))
                }
            }
            .padding(.top, 10)
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                detailTile("Latency", snapshot.network.latencyMilliseconds.map { "\(Int($0.rounded())) ms" } ?? "—")
                detailTile("Wi-Fi", snapshot.network.signalStrengthDBm.map { "\($0) dBm" } ?? "—")
                detailTile("Link", snapshot.network.transmitRateBitsPerSecond.map { "\($0 / 1_000_000)M" } ?? "—")
            }
        }
        .padding(18)
    }

    private func rate(_ value: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(max(0, value)), countStyle: .decimal) + "/s"
    }

    private func detailTile(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).foregroundStyle(WidgetTheme.tertiary)
            Text(value).font(.system(size: 16, weight: .heavy, design: .rounded)).monospacedDigit().lineLimit(1)
        }
        .font(.system(size: 9.5))
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WidgetTheme.inset, in: RoundedRectangle(cornerRadius: 11))
    }
}
