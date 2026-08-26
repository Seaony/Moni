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
