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

struct SensorsMediumWidget: Widget {
    var body: some WidgetConfiguration {
        moniWidgetConfiguration(
            kind: .sensorsMedium,
            displayName: "Sensors",
            description: "查看处理器、图形处理器、电池等温度传感器。",
            family: .systemMedium
        )
    }
}

struct SensorsMediumWidgetView: View {
    let snapshot: WidgetSystemSnapshot

    private var sensors: [WidgetSystemSnapshot.Sensor] {
        var values = snapshot.sensors
        append("CPU die", value: snapshot.power.cpuTemperatureCelsius, to: &values)
        append("GPU die", value: snapshot.power.gpuTemperatureCelsius, to: &values)
        append("Battery", value: snapshot.power.batteryTemperatureCelsius, to: &values)
        return Array(values.prefix(6))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WidgetHeader(title: "Sensors", symbol: "thermometer.medium", color: WidgetTheme.orange, trailing: isHot ? "High temperature" : "No throttling")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), alignment: .leading, spacing: 14) {
                ForEach(Array(sensors.enumerated()), id: \.offset) { _, sensor in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(sensor.name)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(WidgetTheme.tertiary)
                            .lineLimit(1)
                        Text("\(Int(sensor.celsius.rounded()))°")
                            .font(.system(size: 20, weight: .heavy, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(color(sensor.celsius))
                    }
                }
            }
            .padding(.top, 14)
        }
        .padding(16)
    }

    private var isHot: Bool { sensors.contains { $0.celsius >= 90 } }

    private func append(_ name: String, value: Double?, to values: inout [WidgetSystemSnapshot.Sensor]) {
        guard let value, !values.contains(where: { $0.name.localizedCaseInsensitiveContains(name) }) else { return }
        values.append(.init(name: name, celsius: value))
    }

    private func color(_ value: Double) -> Color {
        value >= 90 ? WidgetTheme.red : value >= 75 ? WidgetTheme.orange : WidgetTheme.foreground
    }
}

struct MemoryMediumWidget: Widget {
    var body: some WidgetConfiguration {
        moniWidgetConfiguration(
            kind: .memoryMedium,
            displayName: "Memory Details",
            description: "查看活跃、联动、压缩与空闲内存的分布。",
            family: .systemMedium
        )
    }
}

struct MemoryMediumWidgetView: View {
    let snapshot: WidgetSystemSnapshot

    private var activeBytes: UInt64 {
        snapshot.memory.usedBytes > snapshot.memory.wiredBytes + snapshot.memory.compressedBytes
            ? snapshot.memory.usedBytes - snapshot.memory.wiredBytes - snapshot.memory.compressedBytes
            : 0
    }

    private var segments: [(String, UInt64, Color)] {
        [
            ("Active", activeBytes, WidgetTheme.blue),
            ("Wired", snapshot.memory.wiredBytes, WidgetTheme.purple),
            ("Compressed", snapshot.memory.compressedBytes, WidgetTheme.orange),
            ("Free", snapshot.memory.freeBytes, WidgetTheme.green)
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WidgetHeader(title: "Memory", symbol: "memorychip", color: WidgetTheme.blue, trailing: bytes(snapshot.memory.totalBytes) + " unified")
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(bytes(snapshot.memory.usedBytes))
                    .font(.system(size: 27, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                Text("used · pressure \(pressure)")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(WidgetTheme.secondary)
            }
            .padding(.top, 8)
            GeometryReader { geometry in
                HStack(spacing: 2) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(segment.2)
                            .frame(width: geometry.size.width * fraction(segment.1))
                    }
                }
            }
            .frame(height: 9)
            .padding(.top, 8)
            HStack(spacing: 12) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    HStack(spacing: 4) {
                        Circle().fill(segment.2).frame(width: 6, height: 6)
                        Text(segment.0).foregroundStyle(WidgetTheme.secondary)
                        Text(bytes(segment.1)).fontWeight(.bold)
                    }
                    .font(.system(size: 9))
                }
            }
            .padding(.top, 8)
            Spacer(minLength: 4)
            Text("Swap \(bytes(snapshot.memory.swapUsedBytes))   Page ins \(snapshot.memory.pageIns.formatted())")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(WidgetTheme.secondary)
        }
        .padding(16)
    }

    private var pressure: String {
        snapshot.memory.usedPercent >= 90 ? "Critical" : snapshot.memory.usedPercent >= 80 ? "High" : "Normal"
    }

    private func fraction(_ value: UInt64) -> CGFloat {
        guard snapshot.memory.totalBytes > 0 else { return 0 }
        return CGFloat(Double(value) / Double(snapshot.memory.totalBytes))
    }

    private func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
    }
}

struct DiskActivityMediumWidget: Widget {
    var body: some WidgetConfiguration {
        moniWidgetConfiguration(
            kind: .diskActivityMedium,
            displayName: "Disk Activity",
            description: "查看磁盘读写速率、IOPS 与健康状态。",
            family: .systemMedium
        )
    }
}

struct DiskActivityMediumWidgetView: View {
    let snapshot: WidgetSystemSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WidgetHeader(title: "Disk Activity", symbol: "internaldrive", color: WidgetTheme.orange, trailing: snapshot.driveModel)
            HStack(alignment: .top, spacing: 18) {
                metric("Read", snapshot.diskReadBytesPerSecond, color: WidgetTheme.cyan)
                metric("Write", snapshot.diskWriteBytesPerSecond, color: WidgetTheme.orange)
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 1) {
                    Text("IOPS").foregroundStyle(WidgetTheme.tertiary)
                    Text("\(Int((snapshot.diskReadOperationsPerSecond + snapshot.diskWriteOperationsPerSecond).rounded()))")
                        .font(.system(size: 21, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                }
                .font(.system(size: 10.5))
            }
            .padding(.top, 8)
            ZStack {
                WidgetLineChart(values: snapshot.histories.diskRead, color: WidgetTheme.cyan)
                WidgetLineChart(values: snapshot.histories.diskWrite, color: WidgetTheme.orange, showsFill: false)
            }
            .frame(height: 43)
            .padding(.top, 5)
            Spacer(minLength: 2)
            HStack(spacing: 14) {
                Text(snapshot.driveTemperatureCelsius.map { "SSD \(Int($0.rounded()))°" } ?? "SSD —")
                if let status = snapshot.driveSmartStatus {
                    Text("S.M.A.R.T. \(status)").foregroundStyle(WidgetTheme.green)
                }
            }
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(WidgetTheme.secondary)
        }
        .padding(16)
    }

    private func metric(_ label: String, _ value: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).foregroundStyle(color).fontWeight(.bold)
            Text(ByteCountFormatter.string(fromByteCount: Int64(max(0, value)), countStyle: .decimal) + "/s")
                .font(.system(size: 20, weight: .heavy, design: .rounded))
                .monospacedDigit()
        }
        .font(.system(size: 10.5))
    }
}

struct ContainersMediumWidget: Widget {
    var body: some WidgetConfiguration {
        moniWidgetConfiguration(
            kind: .containersMedium,
            displayName: "Containers",
            description: "查看本机容器引擎及连接状态。",
            family: .systemMedium
        )
    }
}

struct ContainersMediumWidgetView: View {
    let snapshot: WidgetSystemSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WidgetHeader(title: "Containers", symbol: "shippingbox", color: WidgetTheme.blue, trailing: snapshot.docker.installation)
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.docker.isRunning ? "Running" : snapshot.docker.isInstalled ? "Stopped" : "Not Found")
                        .font(.system(size: 28, weight: .heavy, design: .rounded))
                    Text(snapshot.docker.isRunning ? "engine connected" : "engine unavailable")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(WidgetTheme.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: snapshot.docker.isRunning ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(snapshot.docker.isRunning ? WidgetTheme.green : WidgetTheme.orange)
            }
            .padding(.top, 12)
            Spacer(minLength: 8)
            HStack(spacing: 10) {
                statusTile("Provider", snapshot.docker.installation ?? "—")
                statusTile("Socket", snapshot.docker.socketPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "—")
            }
        }
        .padding(16)
    }

    private func statusTile(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).foregroundStyle(WidgetTheme.tertiary)
            Text(value).fontWeight(.bold).lineLimit(1)
        }
        .font(.system(size: 10.5))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WidgetTheme.inset, in: RoundedRectangle(cornerRadius: 10))
    }
}
