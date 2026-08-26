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

struct StorageSmallWidget: Widget {
    var body: some WidgetConfiguration {
        moniWidgetConfiguration(
            kind: .storageSmall,
            displayName: "Storage",
            description: "查看系统磁盘空间与实时读写速率。",
            family: .systemSmall
        )
    }
}

struct StorageSmallWidgetView: View {
    let snapshot: WidgetSystemSnapshot

    private var usedPercent: Double { snapshot.volume?.usedPercent ?? 0 }
    private var accent: Color { usedPercent >= 90 ? WidgetTheme.red : WidgetTheme.orange }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WidgetHeader(title: "Storage", symbol: "internaldrive", color: WidgetTheme.orange)
            Spacer(minLength: 4)
            WidgetRing(progress: usedPercent / 100, color: accent) {
                VStack(spacing: 1) {
                    Text("\(Int(usedPercent.rounded()))%")
                        .font(.system(size: 25, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                    Text(snapshot.volume.map { "\(bytes($0.availableBytes)) free" } ?? "Unavailable")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(WidgetTheme.tertiary)
                        .minimumScaleFactor(0.7)
                }
            }
            .frame(width: 103, height: 103)
            .frame(maxWidth: .infinity)
            Spacer(minLength: 4)
            HStack(spacing: 12) {
                rate("R", snapshot.diskReadBytesPerSecond)
                rate("W", snapshot.diskWriteBytesPerSecond)
            }
        }
        .padding(16)
    }

    private func rate(_ label: String, _ value: Double) -> some View {
        Text("\(label) \(ByteCountFormatter.string(fromByteCount: Int64(max(0, value)), countStyle: .decimal))/s")
            .font(.system(size: 10, weight: .bold))
            .monospacedDigit()
            .lineLimit(1)
    }

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}

struct WiFiSmallWidget: Widget {
    var body: some WidgetConfiguration {
        moniWidgetConfiguration(
            kind: .wifiSmall,
            displayName: "Wi-Fi",
            description: "查看当前无线网络的信号、信道与连接速率。",
            family: .systemSmall
        )
    }
}

struct WiFiSmallWidgetView: View {
    let snapshot: WidgetSystemSnapshot

    private var signal: Int { snapshot.network.signalStrengthDBm ?? -100 }
    private var strength: Double { min(1, max(0, Double(signal + 100) / 60)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WidgetHeader(title: "Wi-Fi", symbol: "wifi", color: WidgetTheme.cyan, trailing: snapshot.network.networkName)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(snapshot.network.signalStrengthDBm.map(String.init) ?? "—")
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                Text("dBm")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(WidgetTheme.secondary)
            }
            .padding(.top, 9)
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(0..<5, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Double(index + 1) / 5 <= strength ? WidgetTheme.cyan : WidgetTheme.track)
                        .frame(height: CGFloat(7 + index * 4))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
            Spacer(minLength: 8)
            HStack(spacing: 10) {
                stat("Channel", snapshot.network.channel ?? "—")
                stat("Link", linkRate)
            }
        }
        .padding(16)
    }

    private var linkRate: String {
        guard let value = snapshot.network.transmitRateBitsPerSecond else { return "—" }
        return "\(value / 1_000_000)M"
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).foregroundStyle(WidgetTheme.tertiary)
            Text(value).fontWeight(.bold).monospacedDigit()
        }
        .font(.system(size: 10.5))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
