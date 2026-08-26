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

struct PowerSmallWidget: Widget {
    var body: some WidgetConfiguration {
        moniWidgetConfiguration(
            kind: .powerSmall,
            displayName: "Power",
            description: "查看电池、温度与风扇状态。",
            family: .systemSmall
        )
    }
}

struct PowerSmallWidgetView: View {
    let snapshot: WidgetSystemSnapshot

    private var battery: Double { snapshot.power.batteryPercent ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WidgetHeader(
                title: "Power",
                symbol: "battery.75percent",
                color: WidgetTheme.yellow,
                trailing: snapshot.power.isCharging ? "Charging" : nil
            )
            Text(snapshot.power.batteryPercent.map { "\(Int($0.rounded()))%" } ?? "—")
                .font(.system(size: 36, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .padding(.top, 9)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(WidgetTheme.track)
                    Capsule()
                        .fill(WidgetTheme.green)
                        .frame(width: geometry.size.width * min(1, max(0, battery / 100)))
                }
            }
            .frame(height: 7)
            .padding(.top, 3)
            Spacer(minLength: 8)
            HStack(spacing: 10) {
                stat("CPU die", snapshot.power.cpuTemperatureCelsius.map { "\(Int($0.rounded()))°" } ?? "—")
                stat("Fan", snapshot.power.fanRPM.map { "\(Int($0.rounded())) rpm" } ?? "—")
            }
        }
        .padding(16)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).foregroundStyle(WidgetTheme.tertiary)
            Text(value).fontWeight(.bold).foregroundStyle(WidgetTheme.foreground).monospacedDigit()
        }
        .font(.system(size: 10.5))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
