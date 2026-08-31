import SwiftUI

struct SummaryView: View {
    @EnvironmentObject private var monitor: SystemMonitor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var selection: MonitorSection
    @AppStorage(PreferenceKey.summaryCardLayout) private var cardLayoutData = Data()
    @AppStorage(PreferenceKey.summaryGridDensity) private var gridDensityValue = SummaryGridDensity.comfortable.rawValue
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

    private var gridDensity: SummaryGridDensity {
        SummaryGridDensity(rawValue: gridDensityValue) ?? .comfortable
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: gridDensity.spacing) {
                healthBanner

                DashboardGridLayout(rowHeight: gridDensity.rowHeight, spacing: gridDensity.spacing) {
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
        }
    }

    private var healthBanner: some View {
        let health = snapshot.systemHealth
        let color = healthColor(health.level)
        return HStack(spacing: 16) {
            ZStack {
                Circle()
                    .stroke(MoniPalette.track, lineWidth: 6)
                Circle()
                    .trim(from: 0, to: Double(health.score) / 100)
                    .stroke(color, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(health.score.formatted())
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .moniNumericTransition(health.score)
            }
            .frame(width: 54, height: 54)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(MoniLocalization.string("System Health"))
                        .font(.system(size: 15, weight: .bold))
                    Text(healthLevelTitle(health.level))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(color)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(color.opacity(0.13))
                        .clipShape(Capsule())
                }
                Text(healthDiagnosis(health.diagnosis))
                    .font(.system(size: 13))
                    .foregroundStyle(MoniPalette.foregroundSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 4) {
                Text(MoniLocalization.string("Memory Pressure"))
                    .font(.system(size: 11))
                    .foregroundStyle(MoniPalette.foregroundTertiary)
                HStack(spacing: 5) {
                    Circle()
                        .fill(memoryPressureColor)
                        .frame(width: 7, height: 7)
                    Text(memoryPressureTitle)
                        .font(.system(size: 12, weight: .semibold))
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MoniPalette.card)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(MoniPalette.line, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }

    private func healthColor(_ level: SystemHealthLevel) -> Color {
        switch level {
        case .excellent: MoniPalette.green
        case .good: MoniPalette.blue
        case .fair: MoniPalette.orange
        case .needsAttention: MoniPalette.red
        }
    }

    private func healthLevelTitle(_ level: SystemHealthLevel) -> String {
        let key = switch level {
        case .excellent: "Excellent"
        case .good: "Good"
        case .fair: "Fair"
        case .needsAttention: "Needs Attention"
        }
        return MoniLocalization.string(key)
    }

    private func healthDiagnosis(_ diagnosis: SystemHealthDiagnosis) -> String {
        switch diagnosis {
        case .allClear:
            MoniLocalization.string("All monitored systems are operating normally.")
        case .smartWarning:
            MoniLocalization.string("Disk health warning. Back up important files now.")
        case let .highCPU(processName):
            processName.map { MoniLocalization.format("%@ is using significant CPU.", $0) }
                ?? MoniLocalization.string("CPU usage is high.")
        case let .memoryPressure(processName):
            processName.map { MoniLocalization.format("%@ is contributing most to memory pressure.", $0) }
                ?? MoniLocalization.string("Memory pressure is high.")
        case let .lowDiskSpace(availableBytes):
            MoniLocalization.format(
                "Startup disk is low on space with %@ available.",
                bytes(UInt64(max(0, availableBytes)))
            )
        case .batteryHealth:
            MoniLocalization.string("Battery health needs attention.")
        case .highTemperature:
            MoniLocalization.string("CPU temperature is elevated.")
        case .busyDisk:
            MoniLocalization.string("Disk activity is unusually high.")
        case .restartRecommended:
            MoniLocalization.string("A restart is recommended after the current long uptime.")
        }
    }

    private var memoryPressureTitle: String {
        let key = switch snapshot.memory.pressure {
        case .normal: "Normal"
        case .warning: "Warning"
        case .critical: "Critical"
        case .unavailable: "Unavailable"
        }
        return MoniLocalization.string(key)
    }

    private var memoryPressureColor: Color {
        switch snapshot.memory.pressure {
        case .normal: MoniPalette.green
        case .warning: MoniPalette.orange
        case .critical: MoniPalette.red
        case .unavailable: MoniPalette.foregroundTertiary
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
        }
    }

    private var hostCard: some View {
        cardButton(.host) {
            MetricCard(title: snapshot.host.name, symbol: MonitorSection.host.symbol, color: MoniPalette.cyan) {
                if cardSize(.host).columns >= 2 {
                    HStack(alignment: .top, spacing: 32) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\(hostOperatingSystemLabel) · \(hostChipLabel)")
                                .font(.system(size: 12))
                                .foregroundStyle(MoniPalette.foregroundSecondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                                .help("Current macOS release installed on this Mac.")
                            Text(formatUptime(snapshot.host.uptime))
                                .font(.system(size: 34, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .moniNumericTransition(Int(snapshot.host.uptime))
                                .help("Time since this Mac last started.")
                            Text("Uptime")
                                .foregroundStyle(MoniPalette.foregroundSecondary)
                                .help("Time since this Mac last started.")
                        }
                        VStack(spacing: 9) {
                            hostHardwareGrid
                            hostLoadRow
                            MetricRow(label: "Processes", value: snapshot.processes.count.formatted(), color: MoniPalette.purple, helpText: "Number of processes currently reported by macOS.")
                        }
                        .frame(maxWidth: .infinity)
                    }
                } else {
                    Text("\(hostOperatingSystemLabel) · \(hostChipLabel)")
                        .font(.system(size: 12))
                        .foregroundStyle(MoniPalette.foregroundSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .help("Current macOS release installed on this Mac.")
                    HStack(alignment: .bottom, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(formatUptime(snapshot.host.uptime))
                                .font(.system(size: 34, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .moniNumericTransition(Int(snapshot.host.uptime))
                                .help("Time since this Mac last started.")
                            Text("Uptime")
                                .foregroundStyle(MoniPalette.foregroundSecondary)
                        }
                        .help("Time since this Mac last started.")
                        Spacer(minLength: 8)
                        hostHardwareGrid
                    }
                    hostLoadRow
                    MetricRow(label: "Processes", value: snapshot.processes.count.formatted(), color: MoniPalette.purple, helpText: "Number of processes currently reported by macOS.")
                }
            }
        }
    }

    private var hostHardwareGrid: some View {
        VStack(spacing: 7) {
            HStack(spacing: 14) {
                hostHardwareStat("Display", hostDisplaySize, help: "Physical diagonal size of the main display.")
                hostHardwareStat("Battery", hostBatteryHealth, help: "Estimated battery health based on maximum capacity compared with design capacity.")
            }
            HStack(spacing: 14) {
                hostHardwareStat("Memory", bytes(snapshot.memory.totalBytes), help: "Total physical unified memory installed in this Mac.")
                hostHardwareStat("Storage", hostStorageCapacity, help: "Total capacity of the startup volume.")
            }
        }
    }

    private func hostHardwareStat(_ label: String, _ value: String, help: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(MoniLocalization.string(label))
                .font(.system(size: 10.5))
                .foregroundStyle(MoniPalette.foregroundSecondary)
            Text(value)
                .font(.system(size: 13.5, weight: .bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .help(MoniLocalization.string(help))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var hostLoadRow: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(MoniPalette.orange)
                .frame(width: 7, height: 7)
            Text("Load")
                .foregroundStyle(MoniPalette.foregroundSecondary)
            Spacer(minLength: 4)
            ForEach(Array(snapshot.host.loadAverages.enumerated()), id: \.offset) { index, value in
                if index > 0 {
                    Text("·")
                }
                Text(String(format: "%.2f", value))
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .moniNumericTransition(value)
                    .help(hostLoadHelp(index))
            }
        }
        .font(.system(size: 12))
    }

    private func hostLoadHelp(_ index: Int) -> String {
        let period = MoniLocalization.string(["1 minute", "5 minutes", "15 minutes"][index])
        return MoniLocalization.format("Average number of runnable or waiting tasks over the last %@.", period)
    }

    private var hostStorageCapacity: String {
        guard let rootVolume = snapshot.volumes.first(where: { $0.mountPath == "/" }),
              rootVolume.totalBytes > 0 else { return "—" }
        return bytes(UInt64(rootVolume.totalBytes))
    }

    private var hostDisplaySize: String {
        snapshot.gpuDevices.first?.mainDisplayDiagonalInches
            .map { "\(Int($0.rounded()))″" } ?? "—"
    }

    private var hostBatteryHealth: String {
        snapshot.power.batteryHealthPercent.map { "\(Int($0.rounded()))%" } ?? "—"
    }

    private var hostOperatingSystemLabel: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let versionNumber = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        let releaseName = version.majorVersion == 26 ? "Tahoe" : "macOS"
        return "\(releaseName) \(versionNumber)"
    }

    private var hostChipLabel: String {
        snapshot.host.chip.replacingOccurrences(of: "Apple ", with: "")
    }

    private var cpuCard: some View {
        cardButton(.cpu) {
            MetricCard(
                title: "CPU",
                symbol: MonitorSection.cpu.symbol,
                color: MoniPalette.pink,
                trailing: "\(snapshot.host.processorCount) cores",
                trailingHelp: "Number of logical CPU cores available to macOS."
            ) {
                HStack(alignment: .bottom, spacing: 12) {
                    Text(percent(snapshot.cpu.total))
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .moniNumericTransition(snapshot.cpu.total)
                        .help("Total CPU time currently used across all cores.")
                    InteractiveSparkline(
                        series: [
                            InteractiveSparklineSeries(
                                name: "CPU",
                                values: monitor.cpuHistory,
                                color: MoniPalette.pink,
                                showsFill: true,
                                formatValue: percent
                            )
                        ],
                        dates: monitor.recentHistoryDates
                    )
                        .frame(height: chartHeight(for: cardSize(.cpu), compact: 66))
                }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    compactCardStat("User", percent(snapshot.cpu.user), color: MoniPalette.pink, help: "CPU time used by apps and other user-space processes.")
                    compactCardStat("System", percent(snapshot.cpu.system), color: MoniPalette.orange, help: "CPU time used by the macOS kernel and system services.")
                    compactCardStat("Nice", percent(snapshot.cpu.nice), color: MoniPalette.yellow, help: "CPU time used by lower-priority processes.")
                    compactCardStat("Idle", percent(snapshot.cpu.idle), color: MoniPalette.green, help: "CPU capacity that is currently unused.")
                }
                .frame(maxHeight: .infinity, alignment: .bottomLeading)
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
                            .help("Percentage of physical memory currently in use.")
                        HStack(spacing: 3) {
                            Text(bytes(snapshot.memory.usedBytes))
                                .help("Physical memory currently in use.")
                            Text("/")
                            Text(bytes(snapshot.memory.totalBytes))
                                .help("Total physical memory installed in this Mac.")
                        }
                            .font(.system(size: 12))
                            .foregroundStyle(MoniPalette.foregroundSecondary)
                    }
                    InteractiveSparkline(
                        series: [
                            InteractiveSparklineSeries(
                                name: "Memory",
                                values: monitor.memoryHistory,
                                color: MoniPalette.blue,
                                showsFill: true,
                                formatValue: percent
                            )
                        ],
                        dates: monitor.recentHistoryDates
                    )
                        .frame(height: chartHeight(for: cardSize(.memory), compact: 66))
                }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    compactCardStat("Used", bytes(snapshot.memory.usedBytes), color: MoniPalette.blue, help: "Physical memory currently occupied by apps, the system, and caches.")
                    compactCardStat("Free", bytes(snapshot.memory.freeBytes), color: MoniPalette.green, help: "Physical memory that is immediately unused.")
                    compactCardStat("Cached", bytes(snapshot.memory.cachedBytes), color: MoniPalette.cyan, help: "Memory holding reusable file data that macOS can reclaim when needed.")
                    compactCardStat("Wired", bytes(snapshot.memory.wiredBytes), color: MoniPalette.orange, help: "Memory reserved by the kernel that cannot be compressed or paged out.")
                }
                .frame(maxHeight: .infinity, alignment: .bottomLeading)
            }
        }
    }

    private func compactCardStat(_ label: String, _ value: String, color: Color, help: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                Text(MoniLocalization.string(label))
                    .foregroundStyle(MoniPalette.foregroundSecondary)
            }
            Text(value)
                .fontWeight(.bold)
                .monospacedDigit()
                .help(MoniLocalization.string(help))
        }
        .font(.system(size: 11.5))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var gpuCard: some View {
        let size = cardSize(.gpu)
        let isWide = size.columns >= 2

        return cardButton(.gpu) {
            MetricCard(
                title: "GPU",
                symbol: MonitorSection.gpu.symbol,
                color: MoniPalette.green,
                trailing: "\(snapshot.gpuDevices.count) device\(snapshot.gpuDevices.count == 1 ? "" : "s")",
                trailingHelp: "Number of GPU devices detected by macOS."
            ) {
                HStack(alignment: .bottom, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Utilization")
                            .foregroundStyle(MoniPalette.foregroundSecondary)
                        Text(MoniLocalization.string(snapshot.gpu.utilizationPercent.map(percent) ?? "No Data"))
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .help("Current overall GPU utilization reported by macOS.")
                        Text(snapshot.gpuDevices.first?.name ?? snapshot.host.chip)
                            .font(.system(size: 11.5))
                            .foregroundStyle(MoniPalette.foregroundSecondary)
                            .lineLimit(1)
                    }
                    InteractiveSparkline(
                        series: [
                            InteractiveSparklineSeries(
                                name: "GPU",
                                values: monitor.gpuHistory,
                                color: MoniPalette.green,
                                showsFill: true,
                                formatValue: percent
                            )
                        ],
                        dates: monitor.gpuHistoryDates
                    )
                        .frame(maxWidth: .infinity)
                        .frame(height: chartHeight(for: size, compact: 66))
                }
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible()), count: isWide ? 3 : 2),
                    spacing: 8
                ) {
                    compactCardStat("Renderer", snapshot.gpu.rendererPercent.map(percent) ?? "—", color: MoniPalette.green, help: "Share of GPU renderer capacity currently in use.")
                    compactCardStat("Tiler", snapshot.gpu.tilerPercent.map(percent) ?? "—", color: MoniPalette.cyan, help: "Share of GPU tiler capacity currently in use.")
                    if isWide {
                        compactCardStat("Allocated", snapshot.gpu.allocatedMemoryBytes.map(bytes) ?? "—", color: MoniPalette.blue, help: "Unified memory currently allocated to GPU workloads.")
                    }
                }
                .frame(maxHeight: .infinity, alignment: .bottomLeading)
            }
        }
    }

    private var networkCard: some View {
        let size = cardSize(.network)

        return cardButton(.network) {
            MetricCard(title: "Network", symbol: MonitorSection.network.symbol, color: MoniPalette.cyan, trailing: "Live") {
                HStack(alignment: .bottom, spacing: 12) {
                    VStack(alignment: .leading, spacing: 1) {
                        Label("Download", systemImage: "arrow.down")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(MoniPalette.cyan)
                            .help("Current incoming network transfer rate.")
                        Text(rate(snapshot.network.downloadBytesPerSecond))
                            .font(.system(size: 23, weight: .bold, design: .rounded))
                            .moniNumericTransition(snapshot.network.downloadBytesPerSecond)
                            .help("Current incoming network transfer rate.")
                        Label("Upload", systemImage: "arrow.up")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(MoniPalette.orange)
                            .help("Current outgoing network transfer rate.")
                        Text(rate(snapshot.network.uploadBytesPerSecond))
                            .font(.system(size: 23, weight: .bold, design: .rounded))
                            .moniNumericTransition(snapshot.network.uploadBytesPerSecond)
                            .help("Current outgoing network transfer rate.")
                    }
                    InteractiveSparkline(
                        series: [
                            InteractiveSparklineSeries(
                                name: "Download",
                                values: monitor.downloadHistory,
                                color: MoniPalette.cyan,
                                showsFill: true,
                                formatValue: rate
                            ),
                            InteractiveSparklineSeries(
                                name: "Upload",
                                values: monitor.uploadHistory,
                                color: MoniPalette.orange,
                                formatValue: rate
                            ),
                        ],
                        dates: monitor.recentHistoryDates
                    )
                    .frame(maxWidth: .infinity)
                    .frame(height: chartHeight(for: size, compact: 72))
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 16) {
                        networkTotal("Received", bytes(snapshot.network.totalReceivedBytes), color: MoniPalette.cyan, help: "Total data received across network interfaces since the counters started.")
                        networkTotal("Sent", bytes(snapshot.network.totalSentBytes), color: MoniPalette.orange, help: "Total data sent across network interfaces since the counters started.")
                    }
                    HStack(spacing: 6) {
                        Circle()
                            .fill(MoniPalette.green)
                            .frame(width: 7, height: 7)
                        Text(primaryNetworkLabel)
                            .foregroundStyle(MoniPalette.foregroundSecondary)
                            .lineLimit(1)
                            .help("Primary network interface and physical Wi-Fi mode.")
                        Spacer(minLength: 4)
                        Text("\(snapshot.network.interfaces.filter(\.isActive).count) active")
                            .foregroundStyle(MoniPalette.foregroundTertiary)
                            .help("Number of network interfaces currently marked active.")
                    }
                    .font(.system(size: 11.5))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
        }
    }

    private func networkTotal(_ label: String, _ value: String, color: Color, help: String) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(MoniLocalization.string(label))
                .foregroundStyle(MoniPalette.foregroundSecondary)
            Text(value)
                .fontWeight(.bold)
                .monospacedDigit()
                .help(MoniLocalization.string(help))
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
            MetricCard(
                title: "Storage",
                symbol: MonitorSection.storage.symbol,
                color: MoniPalette.orange,
                trailing: "\(snapshot.volumes.count) volumes",
                trailingHelp: "Number of currently mounted storage volumes."
            ) {
                if snapshot.volumes.isEmpty {
                    Text("No mounted volumes")
                        .foregroundStyle(MoniPalette.foregroundSecondary)
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
                        networkTotal("Read", rate(snapshot.diskActivity.readBytesPerSecond), color: MoniPalette.cyan, help: "Current rate of data being read from storage devices.")
                        networkTotal("Write", rate(snapshot.diskActivity.writeBytesPerSecond), color: MoniPalette.orange, help: "Current rate of data being written to storage devices.")
                    }
                    .frame(maxHeight: .infinity, alignment: .bottomLeading)
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
                    .help("Percentage of \(volume.mountPath) currently used.")
            }
            ProgressView(value: volume.usedPercent, total: 100)
                .tint(volume.usedPercent >= 90 ? MoniPalette.red : MoniPalette.orange)
                .moniAnimation(MoniMotion.data, value: volume.usedPercent)
            HStack(spacing: 3) {
                Text(bytes(UInt64(volume.usedBytes)))
                    .help("Storage currently used on \(volume.mountPath).")
                Text("/")
                Text(bytes(UInt64(volume.totalBytes)))
                    .help("Total storage capacity of \(volume.mountPath).")
                Text("used")
            }
                .font(.system(size: 10.5))
                .foregroundStyle(MoniPalette.foregroundSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 11.5))
    }

    private var processCard: some View {
        let size = cardSize(.processes)
        let itemsPerColumn = size.rows == 1 ? 3 : size.rows * 4

        return cardButton(.processes) {
            MetricCard(
                title: "Processes",
                symbol: MonitorSection.processes.symbol,
                color: MoniPalette.purple,
                trailing: snapshot.processes.count.formatted(),
                trailingHelp: "Number of processes currently reported by macOS."
            ) {
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.flexible(), spacing: 18, alignment: .leading),
                        count: size.columns
                    ),
                    alignment: .leading,
                    spacing: size.rows == 1 ? 0 : 9
                ) {
                    ForEach(snapshot.processes.prefix(size.columns * itemsPerColumn)) { process in
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
                        .foregroundStyle(MoniPalette.foregroundTertiary)
                        .help("Process identifier assigned by macOS.")
                }
                Spacer(minLength: 4)
                Text("\(percent(process.cpuPercent)) CPU")
                    .monospacedDigit()
                    .help("Current CPU share used by \(process.name).")
                Text("\(percent(memoryPercent)) MEM")
                    .monospacedDigit()
                    .foregroundStyle(MoniPalette.foregroundSecondary)
                    .help("Share of total physical memory used by \(process.name).")
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
                            .foregroundStyle(MoniPalette.foregroundSecondary)
                        Text(MoniLocalization.string(snapshot.power.batteryPercent.map(percent) ?? "No Battery"))
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .moniNumericTransition(snapshot.power.batteryPercent)
                            .help("Current battery charge level. “No Battery” is shown on desktop Macs.")
                    }
                    .layoutPriority(1)
                    InteractiveSparkline(
                        series: [
                            InteractiveSparklineSeries(
                                name: "CPU die",
                                values: monitor.cpuTemperatureHistory,
                                color: MoniPalette.orange,
                                showsFill: true,
                                formatValue: { String(format: "%.1f°C", $0) }
                            )
                        ],
                        dates: monitor.cpuTemperatureHistoryDates
                    )
                        .frame(maxWidth: .infinity)
                        .frame(height: chartHeight(for: size, compact: 54))
                }
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible()), count: isWide ? 4 : 2),
                    spacing: 10
                ) {
                    powerStat("Fan", snapshot.power.fans.first.map { String(format: "%.0f rpm", $0.revolutionsPerMinute) } ?? "—", help: "Rotation speed of the first detected cooling fan.")
                    powerStat("Cycles", snapshot.power.cycleCount.map(String.init) ?? "—", help: "Number of completed battery charge cycles.")
                    powerStat("Power draw", snapshot.power.systemPowerWatts.map { String(format: "%.1f W", $0) } ?? "—", help: "Estimated electrical power currently consumed by the system.")
                    powerStat("Health", snapshot.power.batteryHealth ?? "—", color: batteryHealthColor, help: "Battery condition reported by macOS.")
                }
                .frame(maxHeight: .infinity, alignment: .bottomLeading)
            }
        }
    }

    private func powerStat(
        _ label: String,
        _ value: String,
        color: Color = MoniPalette.foreground,
        help: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(MoniLocalization.string(label))
                .foregroundStyle(MoniPalette.foregroundSecondary)
            Text(value)
                .fontWeight(.bold)
                .foregroundStyle(color)
                .monospacedDigit()
                .lineLimit(1)
                .help(MoniLocalization.string(help))
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
                trailing: docker.isRunning
                    ? "\(docker.runningContainerCount)/\(docker.containers.count) up"
                    : nil,
                trailingHelp: "Running Docker containers compared with all detected containers."
            ) {
                if cardSize(.docker).columns >= 2 {
                    HStack(alignment: .top, spacing: 32) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(MoniLocalization.string(docker.statusTitle))
                                .font(.system(size: 30, weight: .bold, design: .rounded))
                            Text(MoniLocalization.string(docker.installation ?? "No supported installation"))
                                .foregroundStyle(MoniPalette.foregroundSecondary)
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            MetricRow(
                                label: "Engine",
                                value: docker.isRunning ? "Connected" : "Unavailable",
                                color: docker.isRunning ? MoniPalette.green : docker.isInstalled ? MoniPalette.orange : MoniPalette.red,
                                helpText: "Whether Moni can currently communicate with the local Docker engine."
                            )
                            Text(MoniLocalization.string(docker.statusReason))
                                .font(.system(size: 11))
                                .foregroundStyle(MoniPalette.foregroundTertiary)
                                .lineLimit(3)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    Text(MoniLocalization.string(docker.statusTitle))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Text(MoniLocalization.string(docker.installation ?? "No supported installation"))
                        .foregroundStyle(MoniPalette.foregroundSecondary)
                    Spacer()
                    MetricRow(
                        label: "Engine",
                        value: docker.isRunning ? "Connected" : "Unavailable",
                        color: docker.isRunning ? MoniPalette.green : docker.isInstalled ? MoniPalette.orange : MoniPalette.red,
                        helpText: "Whether Moni can currently communicate with the local Docker engine."
                    )
                    Text(MoniLocalization.string(docker.statusReason))
                        .font(.system(size: 11))
                        .foregroundStyle(MoniPalette.foregroundTertiary)
                        .lineLimit(2)
                }
            }
        }
    }

    private var powerSourceTitle: String? {
        if snapshot.power.isCharging { return MoniLocalization.string("Charging") }
        if snapshot.power.isExternalPowerConnected { return MoniLocalization.string("AC Power") }
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
        var cards: Set<DashboardCardID> = []
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
        if cardSize(source).columns == 3 {
            let firstCardInRow = cardDragContext.frames
                .filter {
                    $0.key != source && abs($0.value.minY - frame.minY) < 6
                }
                .min(by: { $0.value.minX < $1.value.minX })?.key
            if let firstCardInRow {
                moveCard(source, firstCardInRow, false)
                return
            }
        }
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
        // The `compact` baselines are tuned for the comfortable row; only grow the
        // chart when the density actually hands the card extra height.
        let compactFill = max(0, gridDensity.rowHeight - SummaryGridDensity.comfortable.rowHeight)
        let additionalRows = CGFloat(size.rows - 1) * (gridDensity.rowHeight + gridDensity.spacing)
        return compact + compactFill + additionalRows
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
        let days = max(0, interval) / 86_400
        let value = days.formatted(
            .number
                .locale(MoniLocalization.currentLanguage.locale)
                .precision(.fractionLength(1))
        )
        return MoniLocalization.format("%@d", value)
    }
}
