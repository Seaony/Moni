import SwiftUI
import WidgetKit

struct NetworkMediumWidget: Widget {
    var body: some WidgetConfiguration {
        moniWidgetConfiguration(
            kind: .networkMedium,
            displayName: "Network",
            description: "查看实时下载、上传速率与网络趋势。",
            family: .systemMedium
        )
    }
}

struct NetworkMediumWidgetView: View {
    let snapshot: WidgetSystemSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WidgetHeader(
                title: "Network",
                symbol: "arrow.up.arrow.down",
                color: WidgetTheme.cyan,
                trailing: networkDetail
            )
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    rate("Download", symbol: "arrow.down", value: snapshot.network.downloadBytesPerSecond, color: WidgetTheme.cyan)
                    rate("Upload", symbol: "arrow.up", value: snapshot.network.uploadBytesPerSecond, color: WidgetTheme.orange)
                }
                .frame(width: 98, alignment: .leading)
                ZStack {
                    WidgetLineChart(values: snapshot.histories.download, color: WidgetTheme.cyan)
                    WidgetLineChart(values: snapshot.histories.upload, color: WidgetTheme.orange, showsFill: false)
                }
                .padding(.top, 8)
            }
            .padding(.top, 10)
        }
        .padding(16)
    }

    private var networkDetail: String {
        [snapshot.network.interfaceName, snapshot.network.physicalMode]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private func rate(_ label: String, symbol: String, value: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Label(label, systemImage: symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(color)
            Text(ByteCountFormatter.string(fromByteCount: Int64(max(0, value)), countStyle: .decimal) + "/s")
                .font(.system(size: 21, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.7)
                .lineLimit(1)
        }
    }
}

struct AIUsageMediumWidget: Widget {
    var body: some WidgetConfiguration {
        moniWidgetConfiguration(
            kind: .aiUsageMedium,
            displayName: "AI Usage",
            description: "查看 AI 总成本、Token 和各服务周额度。",
            family: .systemMedium
        )
    }
}

struct AIUsageMediumWidgetView: View {
    let snapshot: WidgetAISnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WidgetHeader(title: "AI Usage", symbol: "sparkles", color: WidgetTheme.indigo, trailing: "This month")
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.estimatedCostUSD?.formatted(.currency(code: "USD").precision(.fractionLength(0))) ?? "—")
                        .font(.system(size: 27, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                    Text(compact(snapshot.totalTokens) + " tokens")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(WidgetTheme.secondary)
                    Spacer(minLength: 4)
                    WidgetBars(values: snapshot.daily.suffix(14).map { Double($0.tokens) }, color: WidgetTheme.indigo)
                        .frame(height: 36)
                }
                .frame(width: 90, alignment: .leading)
                VStack(spacing: 7) {
                    ForEach(Array(snapshot.providers.prefix(3).enumerated()), id: \.offset) { index, provider in
                        providerRow(provider, color: providerColor(index))
                    }
                }
            }
            .padding(.top, 10)
        }
        .padding(16)
    }

    private func providerRow(_ provider: WidgetAIProvider, color: Color) -> some View {
        let remaining = provider.quotas.first?.remainingPercent
        return VStack(spacing: 3) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(provider.name == "Claude" ? "Claude Code" : provider.name)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(compact(provider.totalTokens))
                    .foregroundStyle(WidgetTheme.tertiary)
                if let remaining {
                    Text("\(Int(remaining.rounded()))%")
                        .fontWeight(.bold)
                        .foregroundStyle(color)
                }
            }
            .font(.system(size: 9.5))
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(WidgetTheme.track)
                    Capsule().fill(color).frame(width: geometry.size.width * min(1, max(0, (remaining ?? 0) / 100)))
                }
            }
            .frame(height: 4)
        }
    }

    private func compact(_ value: UInt64) -> String {
        value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }

    private func providerColor(_ index: Int) -> Color {
        [WidgetTheme.orange, WidgetTheme.cyan, WidgetTheme.blue][index % 3]
    }
}

struct TopProcessesMediumWidget: Widget {
    var body: some WidgetConfiguration {
        moniWidgetConfiguration(
            kind: .topProcessesMedium,
            displayName: "Top Processes",
            description: "查看 CPU 使用率最高的进程。",
            family: .systemMedium
        )
    }
}

struct TopProcessesMediumWidgetView: View {
    let snapshot: WidgetSystemSnapshot

    private var topProcesses: [WidgetSystemSnapshot.Process] {
        Array(snapshot.processes.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(4))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WidgetHeader(title: "Top Processes", symbol: "list.bullet.rectangle", color: WidgetTheme.purple, trailing: snapshot.processCount.formatted())
            VStack(spacing: 7) {
                ForEach(Array(topProcesses.enumerated()), id: \.offset) { _, process in
                    HStack(spacing: 8) {
                        Text(process.name)
                            .fontWeight(.semibold)
                            .lineLimit(1)
                            .frame(width: 92, alignment: .leading)
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Capsule().fill(WidgetTheme.track)
                                Capsule().fill(WidgetTheme.pink).frame(width: geometry.size.width * min(1, process.cpuPercent / 100))
                            }
                        }
                        .frame(height: 5)
                        Text("\(Int(process.cpuPercent.rounded()))%")
                            .fontWeight(.bold)
                            .monospacedDigit()
                            .frame(width: 34, alignment: .trailing)
                        Text(bytes(process.memoryBytes))
                            .foregroundStyle(WidgetTheme.tertiary)
                            .monospacedDigit()
                            .frame(width: 50, alignment: .trailing)
                    }
                    .font(.system(size: 10.5))
                }
            }
            .padding(.top, 12)
        }
        .padding(16)
    }

    private func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
    }
}
