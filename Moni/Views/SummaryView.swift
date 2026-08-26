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
    @State private var liveCardSizes: [DashboardCardID: DashboardCardSize] = [:]
    @State private var draggingCard: DashboardCardID?
    @State private var cardDragContext = DashboardCardDragContext()
    @State private var cardDragPreview: DashboardCardDragPreview?

    private var snapshot: SystemSnapshot { monitor.snapshot }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            DashboardGridLayout {
                ForEach(orderedCards) { card in
                    ResizableDashboardCard(
                        card: card,
                        size: cardSize(card),
                        limits: card.limits,
                        onResizeChanged: { previewCardResize($0, for: card) },
                        onResizeEnded: { finishCardResize($0, for: card) },
                        onMoveStarted: beginCardMove,
                        onMoveChanged: previewCardMove,
                        onMoveEnded: finishCardMove,
                        draggingCard: $draggingCard
                    ) {
                        cardView(card)
                    }
                    .transition(reduceMotion ? .identity : MoniMotion.itemTransition)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .coordinateSpace(name: DashboardGridCoordinateSpace.name)
            .onPreferenceChange(DashboardCardFrameKey.self) { frames in
                cardDragContext.frames = frames
            }
            .moniAnimation(MoniMotion.dashboardReflow, value: cardLayoutData)
            .moniAnimation(MoniMotion.dashboardReflow, value: orderedCards.map(\.rawValue))
            .overlay(alignment: .topLeading) {
                if let preview = cardDragPreview {
                    cardView(preview.card)
                        .frame(width: preview.size.width, height: preview.size.height)
                        .offset(
                            x: preview.location.x - preview.pointerOffset.width,
                            y: preview.location.y - preview.pointerOffset.height
                        )
                        .allowsHitTesting(false)
                        .zIndex(2)
                }
            }
        }
        .task {
            aiUsage.loadIfNeeded(
                days: aiUsageRangeDays,
                includeQuotas: true,
                allowClaudeKeychainPrompt: true
            )
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
                if cardSize(.host).columns >= 2 {
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
                        .frame(height: chartHeight(for: cardSize(.cpu), compact: 66))
                }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    compactCardStat("User", percent(snapshot.cpu.user), color: MoniPalette.pink)
                    compactCardStat("System", percent(snapshot.cpu.system), color: MoniPalette.orange)
                    compactCardStat("Nice", percent(snapshot.cpu.nice), color: MoniPalette.yellow)
                    compactCardStat("Idle", percent(snapshot.cpu.idle), color: MoniPalette.green)
                }
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
                        .frame(height: chartHeight(for: cardSize(.memory), compact: 66))
                }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    compactCardStat("Used", bytes(snapshot.memory.usedBytes), color: MoniPalette.blue)
                    compactCardStat("Free", bytes(snapshot.memory.freeBytes), color: MoniPalette.green)
                    compactCardStat("Cached", bytes(snapshot.memory.cachedBytes), color: MoniPalette.cyan)
                    compactCardStat("Wired", bytes(snapshot.memory.wiredBytes), color: MoniPalette.orange)
                }
            }
        }
    }

    private func compactCardStat(_ label: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                Text(label)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .fontWeight(.bold)
                .monospacedDigit()
        }
        .font(.system(size: 11.5))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var gpuCard: some View {
        let size = cardSize(.gpu)
        let isWide = size.columns >= 2

        return cardButton(.gpu) {
            MetricCard(title: "GPU", symbol: MonitorSection.gpu.symbol, color: MoniPalette.green, trailing: "\(snapshot.gpuDevices.count) device\(snapshot.gpuDevices.count == 1 ? "" : "s")") {
                HStack(alignment: .bottom, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Utilization")
                            .foregroundStyle(.secondary)
                        Text(snapshot.gpu.utilizationPercent.map(percent) ?? "No Data")
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                        Text(snapshot.gpuDevices.first?.name ?? snapshot.host.chip)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Sparkline(values: monitor.gpuHistory, color: MoniPalette.green)
                        .frame(maxWidth: isWide ? .infinity : 104)
                        .frame(height: chartHeight(for: size, compact: 66))
                }
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible()), count: isWide ? 3 : 2),
                    spacing: 8
                ) {
                    compactCardStat("Renderer", snapshot.gpu.rendererPercent.map(percent) ?? "—", color: MoniPalette.green)
                    compactCardStat("Tiler", snapshot.gpu.tilerPercent.map(percent) ?? "—", color: MoniPalette.cyan)
                    if isWide {
                        compactCardStat("Allocated", snapshot.gpu.allocatedMemoryBytes.map(bytes) ?? "—", color: MoniPalette.blue)
                    }
                }
            }
        }
    }

    private var networkCard: some View {
        let size = cardSize(.network)
        let isWide = size.columns >= 2

        return cardButton(.network) {
            MetricCard(title: "Network", symbol: MonitorSection.network.symbol, color: MoniPalette.cyan, trailing: "Live") {
                HStack(alignment: .bottom, spacing: 12) {
                    VStack(alignment: .leading, spacing: 1) {
                        Label("Download", systemImage: "arrow.down")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(MoniPalette.cyan)
                        Text(rate(snapshot.network.downloadBytesPerSecond))
                            .font(.system(size: 23, weight: .bold, design: .rounded))
                            .moniNumericTransition(snapshot.network.downloadBytesPerSecond)
                        Label("Upload", systemImage: "arrow.up")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(MoniPalette.orange)
                        Text(rate(snapshot.network.uploadBytesPerSecond))
                            .font(.system(size: 23, weight: .bold, design: .rounded))
                            .moniNumericTransition(snapshot.network.uploadBytesPerSecond)
                    }
                    ZStack {
                        Sparkline(values: monitor.downloadHistory, color: MoniPalette.cyan)
                        Sparkline(values: monitor.uploadHistory, color: MoniPalette.orange, showsFill: false)
                    }
                    .frame(maxWidth: isWide ? .infinity : 112)
                    .frame(height: chartHeight(for: size, compact: 72))
                }
                HStack(spacing: 16) {
                    networkTotal("Received", bytes(snapshot.network.totalReceivedBytes), color: MoniPalette.cyan)
                    networkTotal("Sent", bytes(snapshot.network.totalSentBytes), color: MoniPalette.orange)
                }
                HStack(spacing: 6) {
                    Circle()
                        .fill(MoniPalette.green)
                        .frame(width: 7, height: 7)
                    Text(primaryNetworkLabel)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(snapshot.network.interfaces.filter(\.isActive).count) active")
                        .foregroundStyle(.tertiary)
                }
                .font(.system(size: 11.5))
            }
        }
    }

    private func networkTotal(_ label: String, _ value: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .fontWeight(.bold)
                .monospacedDigit()
        }
        .font(.system(size: 11.5))
    }

    private var primaryNetworkLabel: String {
        [snapshot.network.primaryInterfaceName, snapshot.network.wifi?.physicalMode]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private var storageCard: some View {
        let size = cardSize(.storage)

        return cardButton(.storage) {
            MetricCard(title: "Storage", symbol: MonitorSection.storage.symbol, color: MoniPalette.orange, trailing: "\(snapshot.volumes.count) volumes") {
                if snapshot.volumes.isEmpty {
                    Text("No mounted volumes")
                        .foregroundStyle(.secondary)
                } else {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible()), count: size.columns),
                        spacing: 8
                    ) {
                        ForEach(snapshot.volumes.prefix(max(2, size.columns * size.rows * 2))) { volume in
                            compactVolume(volume)
                        }
                    }
                    HStack(spacing: 16) {
                        networkTotal("Read", rate(snapshot.diskActivity.readBytesPerSecond), color: MoniPalette.cyan)
                        networkTotal("Write", rate(snapshot.diskActivity.writeBytesPerSecond), color: MoniPalette.orange)
                    }
                }
            }
        }
    }

    private func compactVolume(_ volume: VolumeUsage) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(volume.mountPath)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(percent(volume.usedPercent))
                    .fontWeight(.bold)
                    .foregroundStyle(volume.usedPercent >= 90 ? MoniPalette.red : MoniPalette.green)
                    .moniNumericTransition(volume.usedPercent)
            }
            ProgressView(value: volume.usedPercent, total: 100)
                .tint(volume.usedPercent >= 90 ? MoniPalette.red : MoniPalette.orange)
                .moniAnimation(MoniMotion.data, value: volume.usedPercent)
            Text("\(bytes(UInt64(volume.usedBytes))) / \(bytes(UInt64(volume.totalBytes))) used")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 11.5))
    }

    private var processCard: some View {
        let size = cardSize(.processes)
        let itemCount = max(4, size.columns * size.rows * 4)

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
        let size = cardSize(.power)
        let isWide = size.columns >= 2

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
                        .frame(height: chartHeight(for: size, compact: 54))
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
                if cardSize(.docker).columns >= 2 {
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
                trailing: "Last \(aiUsageRangeDays) days",
                trailingSymbol: "chevron.right"
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
                } else if size.columns >= 2 {
                    HStack(alignment: .top, spacing: 16) {
                        aiUsageOverview
                            .frame(width: size.columns == 3 ? 190 : 150)
                        aiUsageProviderStrip
                    }
                    .frame(maxHeight: .infinity)
                } else {
                    aiUsageOverview
                    if size.rows >= 2 {
                        aiUsageProviderStrip
                            .frame(height: 136)
                    }
                }
            }
        }
    }

    private var aiUsageOverview: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(aiUsage.summary.estimatedCostUSD.map(currency) ?? "—")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .monospacedDigit()
                .moniNumericTransition(aiUsage.summary.estimatedCostUSD)
            Text(
                "\(compactTokens(aiUsage.summary.totalTokens)) tokens · "
                    + "\(aiUsage.summary.providers.count) account"
                    + (aiUsage.summary.providers.count == 1 ? "" : "s")
            )
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            DailyUsageChart(values: aiUsage.summary.daily)
                .frame(minHeight: 40, maxHeight: .infinity)
                .padding(.top, 14)
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private var aiUsageProviderStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 12) {
                ForEach(aiUsage.summary.providers) { provider in
                    aiUsageProviderCard(provider)
                        .frame(width: 236)
                }
            }
        }
    }

    private func aiUsageProviderCard(_ provider: AIProviderUsage) -> some View {
        let color = aiProviderColor(provider)
        let quota = provider.quotaWindows.first {
            $0.label.localizedCaseInsensitiveContains("week")
        } ?? provider.quotaWindows.first

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                Text(provider.provider == "Claude" ? "Claude Code" : provider.provider)
                    .font(.system(size: 13.5, weight: .bold))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(provider.planName ?? "Local logs")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(compactTokens(provider.totalTokens))
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(provider.estimatedCostUSD.map(currency) ?? "unpriced")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.top, 8)

            if let quota {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(quota.label) left")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(quota.remainingPercent.rounded()))%")
                        .fontWeight(.bold)
                        .foregroundStyle(color)
                        .monospacedDigit()
                }
                .font(.system(size: 11.5))
                .padding(.top, 12)

                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(MoniPalette.track)
                        Capsule()
                            .fill(color)
                            .frame(width: geometry.size.width * CGFloat(quota.remainingPercent / 100))
                    }
                }
                .frame(height: 6)
                .padding(.top, 6)
            } else {
                HStack {
                    Text("Local usage")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(provider.requestCount.formatted()) requests")
                        .fontWeight(.semibold)
                        .monospacedDigit()
                }
                .font(.system(size: 11.5))
                .padding(.top, 12)
            }

            Spacer(minLength: 8)

            HStack(alignment: .bottom, spacing: 8) {
                Text(quotaResetLabel(quota))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(provider.models.first?.model ?? "Model unavailable")
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .font(.system(size: 11.5))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(MoniPalette.inset)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func aiProviderColor(_ provider: AIProviderUsage) -> Color {
        switch provider.provider {
        case "Codex": MoniPalette.cyan
        case "Claude": MoniPalette.claude
        case "Qwen Code": MoniPalette.purple
        case "Gemini CLI": MoniPalette.blue
        case "Kimi Code": MoniPalette.yellow
        case "DeepSeek Harness": MoniPalette.indigo
        case "OpenCode": MoniPalette.green
        default: MoniPalette.foregroundSecondary
        }
    }

    private func quotaResetLabel(_ quota: AIQuotaWindow?) -> String {
        guard let quota else { return "Local logs" }
        if let resetsAt = quota.resetsAt {
            return "resets in \(resetDuration(until: resetsAt))"
        }
        if let minutes = quota.windowMinutes {
            return "\(compactDuration(minutes: minutes)) window"
        }
        return "Reset unavailable"
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
        liveCardSizes[card] ?? DashboardCardLayout.decode(cardLayoutData).size(for: card)
    }

    private func previewCardResize(_ size: DashboardCardSize, for card: DashboardCardID) {
        if reduceMotion {
            liveCardSizes[card] = size
        } else {
            withAnimation(MoniMotion.dashboardReflow) {
                liveCardSizes[card] = size
            }
        }
    }

    private func finishCardResize(_ size: DashboardCardSize, for card: DashboardCardID) {
        var layout = DashboardCardLayout.decode(cardLayoutData)
        let finish = {
            if layout.size(for: card) != size {
                layout.setSize(size, for: card)
                cardLayoutData = layout.encoded()
            }
            liveCardSizes.removeValue(forKey: card)
        }
        if reduceMotion {
            finish()
        } else {
            withAnimation(MoniMotion.dashboardSnap) {
                finish()
            }
        }
    }

    private func moveCard(
        _ source: DashboardCardID,
        _ target: DashboardCardID,
        _ placeAfter: Bool
    ) {
        var layout = DashboardCardLayout.decode(cardLayoutData)
        guard layout.move(source, relativeTo: target, placeAfter: placeAfter) else { return }
        let move = { cardLayoutData = layout.encoded() }
        if reduceMotion {
            move()
        } else {
            withAnimation(MoniMotion.dashboardReflow) {
                move()
            }
        }
    }

    private func beginCardMove(
        _ card: DashboardCardID,
        _ frame: CGRect,
        _ startLocation: CGPoint
    ) {
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            cardDragPreview = DashboardCardDragPreview(
                card: card,
                size: frame.size,
                pointerOffset: CGSize(
                    width: startLocation.x - frame.minX,
                    height: startLocation.y - frame.minY
                ),
                location: startLocation
            )
        }
    }

    private func previewCardMove(_ source: DashboardCardID, _ location: CGPoint) {
        if var preview = cardDragPreview, preview.card == source {
            var transaction = Transaction()
            transaction.animation = nil
            preview.location = location
            withTransaction(transaction) {
                cardDragPreview = preview
            }
        }
        let target = cardDragContext.frames
            .filter { card, frame in
                card != source && frame.insetBy(dx: -6, dy: -6).contains(location)
            }
            .min { lhs, rhs in
                distanceSquared(from: location, to: lhs.value)
                    < distanceSquared(from: location, to: rhs.value)
            }
        guard let (card, frame) = target else { return }
        moveCard(source, card, location.x >= frame.midX)
    }

    private func finishCardMove(_ card: DashboardCardID) {
        guard draggingCard == card else { return }
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            cardDragPreview = nil
            draggingCard = nil
        }
    }

    private func distanceSquared(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = point.x - rect.midX
        let dy = point.y - rect.midY
        return dx * dx + dy * dy
    }

    private func chartHeight(for size: DashboardCardSize, compact: CGFloat) -> CGFloat {
        compact + CGFloat(size.rows - 1) * 179
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
        "$" + value.formatted(
            .number.grouping(.automatic).precision(.fractionLength(value < 0.01 ? 4 : 2))
        )
    }

    private func resetDuration(until date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSinceNow))
        let days = seconds / 86_400
        let hours = seconds % 86_400 / 3_600
        let minutes = seconds % 3_600 / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    private func compactDuration(minutes: Int) -> String {
        if minutes >= 1_440 { return "\(minutes / 1_440)d" }
        if minutes >= 60 { return "\(minutes / 60)h" }
        return "\(minutes)m"
    }

    private func formatUptime(_ interval: TimeInterval) -> String {
        let days = Int(interval) / 86_400
        let hours = (Int(interval) % 86_400) / 3_600
        return "\(days)d \(hours)h"
    }
}
