import SwiftUI
import WidgetKit

struct CPUSmallWidget: Widget {
    var body: some WidgetConfiguration {
        moniWidgetConfiguration(
            kind: .cpuSmall,
            displayName: "CPU",
            description: "查看处理器总负载、用户态与系统态占比。",
            family: .systemSmall
        )
    }
}

struct CPUSmallWidgetView: View {
    let snapshot: WidgetSystemSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WidgetHeader(
                title: "CPU",
                symbol: "cpu",
                color: WidgetTheme.pink,
                trailing: "\(snapshot.cpu.perCore.count) cores"
            )
            Text("\(Int(snapshot.cpu.total.rounded()))%")
                .font(.system(size: 38, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.75)
                .lineLimit(1)
                .padding(.top, 8)
            Text("\(Int(snapshot.cpu.user.rounded()))% user · \(Int(snapshot.cpu.system.rounded()))% sys")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(WidgetTheme.secondary)
                .monospacedDigit()
                .lineLimit(1)
            Spacer(minLength: 8)
            WidgetBars(values: snapshot.cpu.perCore, color: WidgetTheme.orange)
                .frame(height: 39)
        }
        .padding(16)
    }
}

struct MemorySmallWidget: Widget {
    var body: some WidgetConfiguration {
        moniWidgetConfiguration(
            kind: .memorySmall,
            displayName: "Memory",
            description: "查看内存使用率、容量与压力状态。",
            family: .systemSmall
        )
    }
}

struct MemorySmallWidgetView: View {
    let snapshot: WidgetSystemSnapshot

    private var pressure: (label: String, color: Color) {
        switch snapshot.memory.usedPercent {
        case 90...: ("Critical", WidgetTheme.red)
        case 80...: ("High", WidgetTheme.orange)
        default: ("Normal", WidgetTheme.green)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WidgetHeader(title: "Memory", symbol: "memorychip", color: WidgetTheme.blue)
            Spacer(minLength: 4)
            WidgetRing(progress: snapshot.memory.usedPercent / 100, color: WidgetTheme.blue) {
                VStack(spacing: 1) {
                    Text("\(Int(snapshot.memory.usedPercent.rounded()))%")
                        .font(.system(size: 25, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                    Text("\(bytes(snapshot.memory.usedBytes)) / \(bytes(snapshot.memory.totalBytes))")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(WidgetTheme.tertiary)
                        .minimumScaleFactor(0.7)
                }
            }
            .frame(width: 103, height: 103)
            .frame(maxWidth: .infinity)
            Spacer(minLength: 4)
            HStack(spacing: 6) {
                Circle().fill(pressure.color).frame(width: 6, height: 6)
                Text("Pressure")
                    .foregroundStyle(WidgetTheme.secondary)
                Text(pressure.label)
                    .foregroundStyle(pressure.color)
                    .fontWeight(.bold)
            }
            .font(.system(size: 10.5))
        }
        .padding(16)
    }

    private func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
    }
}
