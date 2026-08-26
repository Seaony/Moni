import SwiftUI

struct SummaryView: View {
    @EnvironmentObject private var monitor: SystemMonitor
    @EnvironmentObject private var aiUsage: AIUsageStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var selection: MonitorSection
    @AppStorage(PreferenceKey.aiUsageRangeDays) private var aiUsageRangeDays = 30
    @AppStorage(PreferenceKey.summaryCardLayout) private var cardLayoutData = Data()
    @AppStorage(PreferenceKey.showHost) private var showHost = true
    @AppStorage(PreferenceKey.showCPU) private var showCPU = true
    @AppStorage(PreferenceKey.showMemory) private var showMemory = true
    @AppStorage(PreferenceKey.showGPU) private var showGPU = true
    @AppStorage(PreferenceKey.showNetwork) private var showNetwork = true
    @AppStorage(PreferenceKey.showStorage) private var showStorage = true
    @AppStorage(PreferenceKey.showProcesses) private var showProcesses = true
    @AppStorage(PreferenceKey.showPower) private var showPower = true
    @AppStorage(PreferenceKey.showDocker) private var showDocker = true

    private var snapshot: SystemSnapshot { monitor.snapshot }
    private var rootVolume: VolumeUsage? { snapshot.volumes.first { $0.mountPath == "/" } }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            DashboardGridLayout {
                ForEach(orderedCards) { card in
                    ResizableDashboardCard(
                        card: card,
                        size: cardSize(card),
                        limits: card.limits,
                        onResize: { setCardSize($0, for: card) },
                        onMove: moveCard
                    ) {
                        cardView(card)
                    }
                    .transition(reduceMotion ? .identity : MoniMotion.itemTransition)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .moniAnimation(value: cardLayoutData)
            .moniAnimation(value: orderedCards.map(\.rawValue))
        }
        .task {
            aiUsage.loadIfNeeded(days: aiUsageRangeDays)
        }
    }

    @ViewBuilder
    private func cardView(_ card: DashboardCardID) -> some View {
        switch card {
        case .host: hostCard
        case .cpu: cpuCard
        case .memory: memoryCard
        case .gpu: gpuCard
        case .network: networkCard
        case .storage: storageCard
        case .processes: processCard
        case .power: powerCard
        case .docker: dockerCard
        case .aiUsage: aiUsageCard
        }
    }

    private var hostCard: some View {
        cardButton(.host) {
            MetricCard(title: snapshot.host.name, symbol: MonitorSection.host.symbol, color: MoniPalette.cyan) {
                if cardSize(.host).columns == 2 {
                    HStack(alignment: .top, spacing: 32) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(snapshot.host.model)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Text(formatUptime(snapshot.host.uptime))
                                .font(.system(size: 34, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .moniNumericTransition(Int(snapshot.host.uptime))
                            Text("Uptime")
                                .foregroundStyle(.secondary)
                        }
                        VStack(spacing: 12) {
                            MetricRow(label: "Load", value: snapshot.host.loadAverages.map { String(format: "%.2f", $0) }.joined(separator: " · "), color: MoniPalette.orange)
                            MetricRow(label: "Processes", value: snapshot.processes.count.formatted(), color: MoniPalette.purple)
                        }
                        .frame(maxWidth: .infinity)
                    }
                } else {
                    Text(snapshot.host.model)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text(formatUptime(snapshot.host.uptime))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .moniNumericTransition(Int(snapshot.host.uptime))
                    Text("Uptime")
                        .foregroundStyle(.secondary)
                    MetricRow(label: "Load", value: snapshot.host.loadAverages.map { String(format: "%.2f", $0) }.joined(separator: " · "), color: MoniPalette.orange)
                    MetricRow(label: "Processes", value: snapshot.processes.count.formatted(), color: MoniPalette.purple)
                }
            }
        }
    }

    private var cpuCard: some View {
        cardButton(.cpu) {
            MetricCard(title: "CPU", symbol: MonitorSection.cpu.symbol, color: MoniPalette.pink, trailing: "\(snapshot.host.processorCount) cores") {
                HStack(alignment: .bottom, spacing: 12) {
                    Text(percent(snapshot.cpu.total))
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .moniNumericTransition(snapshot.cpu.total)
                    Sparkline(values: monitor.cpuHistory, color: MoniPalette.pink)
                        .frame(height: cardSize(.cpu).rows == 2 ? 245 : 66)
                }
                MetricRow(label: "User", value: percent(snapshot.cpu.user), color: MoniPalette.pink)
                MetricRow(label: "System", value: percent(snapshot.cpu.system), color: MoniPalette.orange)
                MetricRow(label: "Idle", value: percent(snapshot.cpu.idle), color: MoniPalette.green)
            }
        }
    }

    private var memoryCard: some View {
        cardButton(.memory) {
            MetricCard(title: "Memory", symbol: MonitorSection.memory.symbol, color: MoniPalette.blue, trailing: "Live") {
                HStack(alignment: .bottom, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(percent(snapshot.memory.usedPercent))
                            .font(.system(size: 36, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .moniNumericTransition(snapshot.memory.usedPercent)
                        Text("\(bytes(snapshot.memory.usedBytes)) / \(bytes(snapshot.memory.totalBytes))")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Sparkline(values: monitor.memoryHistory, color: MoniPalette.blue)
                        .frame(height: cardSize(.memory).rows == 2 ? 245 : 66)
                }
                MetricRow(label: "Free", value: bytes(snapshot.memory.freeBytes), color: MoniPalette.green)
                MetricRow(label: "Cached", value: bytes(snapshot.memory.cachedBytes), color: MoniPalette.cyan)
                MetricRow(label: "Wired", value: bytes(snapshot.memory.wiredBytes), color: MoniPalette.orange)
            }
        }
    }

    private var gpuCard: some View {
        cardButton(.gpu) {
            MetricCard(title: "GPU", symbol: MonitorSection.gpu.symbol, color: MoniPalette.green, trailing: "\(snapshot.gpuDevices.count) device\(snapshot.gpuDevices.count == 1 ? "" : "s")") {
                if cardSize(.gpu).columns == 2 {
                    HStack(alignment: .top, spacing: 32) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Utilization")
                                .foregroundStyle(.secondary)
                            Text(snapshot.gpu.utilizationPercent.map(percent) ?? "No Data")
                                .font(.system(size: 30, weight: .bold, design: .rounded))
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Text(snapshot.gpuDevices.first?.name ?? snapshot.host.chip)
                                .fontWeight(.semibold)
                            if let memory = snapshot.gpu.allocatedMemoryBytes {
                                Text("\(bytes(memory)) allocated")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    Text("Utilization")
                        .foregroundStyle(.secondary)
                    Text(snapshot.gpu.utilizationPercent.map(percent) ?? "No Data")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Text(snapshot.gpuDevices.first?.name ?? snapshot.host.chip)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let memory = snapshot.gpu.allocatedMemoryBytes {
                        Text("\(bytes(memory)) allocated")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private var networkCard: some View {
        cardButton(.network) {
            MetricCard(title: "Network", symbol: MonitorSection.network.symbol, color: MoniPalette.cyan, trailing: "Live") {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("↓ \(rate(snapshot.network.downloadBytesPerSecond))")
                            .foregroundStyle(MoniPalette.cyan)
                            .moniNumericTransition(snapshot.network.downloadBytesPerSecond)
                        Text("↑ \(rate(snapshot.network.uploadBytesPerSecond))")
                            .foregroundStyle(MoniPalette.orange)
                            .moniNumericTransition(snapshot.network.uploadBytesPerSecond)
                    }
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    Sparkline(values: monitor.downloadHistory, color: MoniPalette.cyan)
                        .frame(height: cardSize(.network).rows == 2 ? 245 : 72)
                }
                MetricRow(label: "Received", value: bytes(snapshot.network.totalReceivedBytes), color: MoniPalette.cyan)
                MetricRow(label: "Sent", value: bytes(snapshot.network.totalSentBytes), color: MoniPalette.orange)
                MetricRow(label: "Active", value: "\(snapshot.network.interfaces.filter(\.isActive).count) interfaces", color: MoniPalette.green)
            }
        }
    }

    private var storageCard: some View {
        cardButton(.storage) {
            MetricCard(title: "Storage", symbol: MonitorSection.storage.symbol, color: MoniPalette.orange, trailing: "\(snapshot.volumes.count) volumes") {
                if let volume = rootVolume {
                    HStack {
                        Text(volume.mountPath)
                            .fontWeight(.semibold)
                        Spacer()
                        Text(percent(volume.usedPercent))
                            .fontWeight(.bold)
                            .foregroundStyle(volume.usedPercent >= 90 ? MoniPalette.red : MoniPalette.green)
                            .moniNumericTransition(volume.usedPercent)
                    }
                    ProgressView(value: volume.usedPercent, total: 100)
                        .tint(volume.usedPercent >= 90 ? MoniPalette.red : MoniPalette.orange)
                        .moniAnimation(MoniMotion.data, value: volume.usedPercent)
                    Text("\(bytes(UInt64(volume.usedBytes))) / \(bytes(UInt64(volume.totalBytes))) used")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    MetricRow(label: "Available", value: bytes(UInt64(max(0, volume.availableBytes))), color: MoniPalette.green)
                } else {
                    Text("No mounted volumes")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var processCard: some View {
        let size = cardSize(.processes)
        let itemCount = size.columns == 2
            ? (size.rows == 2 ? 12 : 8)
            : (size.rows == 2 ? 9 : 4)

        return cardButton(.processes) {
            MetricCard(title: "Processes", symbol: MonitorSection.processes.symbol, color: MoniPalette.purple, trailing: snapshot.processes.count.formatted()) {
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.flexible(), spacing: 18, alignment: .leading),
                        count: size.columns
                    ),
                    alignment: .leading,
                    spacing: 9
                ) {
                    ForEach(snapshot.processes.prefix(itemCount)) { process in
                        processSummaryRow(process)
                    }
                }
            }
        }
    }

    private func processSummaryRow(_ process: ProcessUsage) -> some View {
        let memoryPercent = snapshot.memory.totalBytes > 0
            ? Double(process.memoryBytes) / Double(snapshot.memory.totalBytes) * 100
            : 0

        return VStack(spacing: 3) {
            HStack(spacing: 7) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(process.name)
                        .lineLimit(1)
                        .fontWeight(.semibold)
                    Text("PID \(process.pid)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 4)
                Text("\(percent(process.cpuPercent)) CPU")
                    .monospacedDigit()
                Text("\(percent(memoryPercent)) MEM")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                ProgressView(value: min(100, process.cpuPercent), total: 100)
                    .tint(MoniPalette.pink)
                ProgressView(value: min(100, memoryPercent), total: 100)
                    .tint(MoniPalette.blue)
            }
        }
        .font(.system(size: 10.5))
    }

    private var powerCard: some View {
        let isWide = cardSize(.power).columns == 2

        return cardButton(.sensors) {
            MetricCard(title: "Power & Sensors", symbol: MonitorSection.sensors.symbol, color: MoniPalette.yellow, trailing: powerSourceTitle) {
                HStack(alignment: .bottom, spacing: 18) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Battery")
                            .foregroundStyle(.secondary)
                        Text(snapshot.power.batteryPercent.map(percent) ?? "No Battery")
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .moniNumericTransition(snapshot.power.batteryPercent)
                    }
                    Spacer()
                    VStack(alignment: .leading, spacing: 3) {
                        Text("CPU die")
                            .foregroundStyle(.secondary)
                        Text(snapshot.power.cpuTemperatureCelsius.map { String(format: "%.1f°C", $0) } ?? "No Data")
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                    }
                    Sparkline(values: monitor.cpuTemperatureHistory, color: MoniPalette.orange)
                        .frame(maxWidth: isWide ? .infinity : 96)
                        .frame(height: 54)
                }
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible()), count: isWide ? 4 : 2),
                    spacing: 10
                ) {
                    powerStat("Fan", snapshot.power.fans.first.map { String(format: "%.0f rpm", $0.revolutionsPerMinute) } ?? "—")
                    powerStat("Cycles", snapshot.power.cycleCount.map(String.init) ?? "—")
                    powerStat("Power draw", snapshot.power.systemPowerWatts.map { String(format: "%.1f W", $0) } ?? "—")
                    powerStat("Health", snapshot.power.batteryHealth ?? "—", color: batteryHealthColor)
                }
            }
        }
    }

    private func powerStat(_ label: String, _ value: String, color: Color = MoniPalette.foreground) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .fontWeight(.bold)
                .foregroundStyle(color)
                .monospacedDigit()
                .lineLimit(1)
        }
        .font(.system(size: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var batteryHealthColor: Color {
        guard let health = snapshot.power.batteryHealth else { return MoniPalette.foregroundSecondary }
        return health == "Normal" ? MoniPalette.green : MoniPalette.red
    }

    private var dockerCard: some View {
        let docker = snapshot.docker
        let color: Color = docker.isRunning ? MoniPalette.blue : docker.isInstalled ? MoniPalette.orange : MoniPalette.foregroundSecondary

        return cardButton(.docker) {
            MetricCard(
                title: "Docker",
                symbol: MonitorSection.docker.symbol,
                color: color,
                trailing: docker.isRunning ? "Live" : nil
            ) {
                if cardSize(.docker).columns == 2 {
                    HStack(alignment: .top, spacing: 32) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(docker.statusTitle)
                                .font(.system(size: 30, weight: .bold, design: .rounded))
                            Text(docker.installation ?? "No supported installation")
                                .foregroundStyle(.secondary)
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            MetricRow(
                                label: "Engine",
                                value: docker.isRunning ? "Connected" : "Unavailable",
                                color: docker.isRunning ? MoniPalette.green : docker.isInstalled ? MoniPalette.orange : MoniPalette.red
                            )
                            Text(docker.statusReason)
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                                .lineLimit(3)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    Text(docker.statusTitle)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Text(docker.installation ?? "No supported installation")
                        .foregroundStyle(.secondary)
                    Spacer()
                    MetricRow(
                        label: "Engine",
                        value: docker.isRunning ? "Connected" : "Unavailable",
                        color: docker.isRunning ? MoniPalette.green : docker.isInstalled ? MoniPalette.orange : MoniPalette.red
                    )
                    Text(docker.statusReason)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
        }
    }

    private var aiUsageCard: some View {
        let size = cardSize(.aiUsage)
        let summary = aiUsage.summary

        return cardButton(.ai) {
            MetricCard(
                title: "AI Usage",
                symbol: MonitorSection.ai.symbol,
                color: MoniPalette.indigo,
                trailing: "\(aiUsageRangeDays) days"
            ) {
                if summary.providers.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(aiUsage.isLoading ? "Scanning" : "No Usage")
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                        Text(
                            aiUsage.isLoading
                                ? "Reading local Codex and Claude usage logs…"
                                : "No Codex or Claude token usage was found in this period."
                        )
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        if aiUsage.isLoading {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                    Spacer()
                    MetricRow(label: "Providers", value: "0", color: MoniPalette.indigo)
                } else if size.columns == 2 {
                    HStack(alignment: .bottom, spacing: 18) {
                        aiUsageTotals
                            .frame(width: 170, alignment: .leading)
                        DailyUsageChart(values: summary.daily)
                            .frame(maxWidth: .infinity)
                            .frame(height: size.rows == 2 ? 280 : 112)
                    }
                    if size.rows == 2 {
                        aiUsageProviders
                    }
                } else {
                    aiUsageTotals
                    if size.rows == 2 {
                        DailyUsageChart(values: summary.daily)
                            .frame(height: 190)
                        aiUsageProviders
                    }
                }
            }
        }
    }

    private var aiUsageTotals: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(compactTokens(aiUsage.summary.totalTokens))
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .monospacedDigit()
                .moniNumericTransition(aiUsage.summary.totalTokens)
            Text("tokens")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            MetricRow(
                label: "Requests",
                value: aiUsage.summary.requestCount.formatted(),
                color: MoniPalette.cyan
            )
            MetricRow(
                label: "Est. cost",
                value: aiUsage.summary.estimatedCostUSD.map(currency) ?? "—",
                color: MoniPalette.green
            )
        }
    }

    private var aiUsageProviders: some View {
        VStack(spacing: 8) {
            ForEach(aiUsage.summary.providers) { provider in
                MetricRow(
                    label: provider.provider,
                    value: "\(compactTokens(provider.totalTokens)) · \(provider.requestCount) req",
                    color: provider.provider == "Codex" ? MoniPalette.cyan : MoniPalette.claude
                )
            }
        }
    }

    private var powerSourceTitle: String? {
        if snapshot.power.isCharging { return "Charging" }
        if snapshot.power.isExternalPowerConnected { return "AC Power" }
        return nil
    }

    private func cardButton<Content: View>(_ target: MonitorSection, @ViewBuilder content: () -> Content) -> some View {
        Button {
            selection = target
        } label: {
            content()
                .contentShape(Rectangle())
        }
        .buttonStyle(MoniPressButtonStyle(scale: 0.985))
        .transition(reduceMotion ? .identity : MoniMotion.itemTransition)
    }

    private var orderedCards: [DashboardCardID] {
        DashboardCardLayout.decode(cardLayoutData).orderedCards(visible: visibleCards)
    }

    private var visibleCards: Set<DashboardCardID> {
        var cards: Set<DashboardCardID> = [.aiUsage]
        if showHost { cards.insert(.host) }
        if showCPU { cards.insert(.cpu) }
        if showMemory { cards.insert(.memory) }
        if showGPU { cards.insert(.gpu) }
        if showNetwork { cards.insert(.network) }
        if showStorage { cards.insert(.storage) }
        if showProcesses { cards.insert(.processes) }
        if showPower { cards.insert(.power) }
        if showDocker { cards.insert(.docker) }
        return cards
    }

    private func cardSize(_ card: DashboardCardID) -> DashboardCardSize {
        DashboardCardLayout.decode(cardLayoutData).size(for: card)
    }

    private func setCardSize(_ size: DashboardCardSize, for card: DashboardCardID) {
        var layout = DashboardCardLayout.decode(cardLayoutData)
        layout.setSize(size, for: card)
        cardLayoutData = layout.encoded()
    }

    private func moveCard(
        _ source: DashboardCardID,
        _ target: DashboardCardID,
        _ placeAfter: Bool
    ) {
        var layout = DashboardCardLayout.decode(cardLayoutData)
        layout.move(source, relativeTo: target, placeAfter: placeAfter)
        cardLayoutData = layout.encoded()
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

    private func compactTokens(_ value: UInt64) -> String {
        value.formatted(.number.notation(.compactName))
    }

    private func currency(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(value < 0.01 ? 4 : 2)))
    }

    private func formatUptime(_ interval: TimeInterval) -> String {
        let days = Int(interval) / 86_400
        let hours = (Int(interval) % 86_400) / 3_600
        return "\(days)d \(hours)h"
    }
}
