import SwiftUI

struct SecondaryDetailView: View {
    let section: MonitorSection
    @Binding var selection: MonitorSection

    var body: some View {
        switch section {
        case .gpu:
            GPUDetailView()
        case .network:
            NetworkDetailView()
        case .storage:
            StorageDetailView(selection: $selection)
        case .sensors:
            PowerDetailView()
        case .docker:
            DockerDetailView(selection: $selection)
        case .disks:
            DiskBrowserView()
        default:
            EmptyView()
        }
    }
}

private struct GPUDetailView: View {
    @EnvironmentObject private var monitor: SystemMonitor
    @State private var historyRange = "1m"

    private var device: GPUDeviceInfo? { monitor.snapshot.gpuDevices.first }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 12) {
                DetailPanel {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("GPU")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(MoniPalette.green)
                        Text(deviceSubtitle)
                            .font(.system(size: 12.5))
                            .foregroundStyle(MoniPalette.foregroundTertiary)
                        Spacer(minLength: 12)
                        SecondaryRangePicker(selection: $historyRange)
                        Text(MoniLocalization.string(monitor.snapshot.gpu.utilizationPercent.map(percent) ?? "No Data"))
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                    }
                    InteractiveSparkline(
                        series: [
                            InteractiveSparklineSeries(
                                name: "GPU",
                                values: monitor.history(.gpu, duration: secondaryHistoryDuration(historyRange)),
                                color: MoniPalette.green,
                                showsFill: true,
                                formatValue: percent
                            )
                        ],
                        dates: monitor.historyDates(.gpu, duration: secondaryHistoryDuration(historyRange))
                    )
                        .frame(height: 160)
                    rangeFooter(historyRange)
                }

                HStack(alignment: .top, spacing: 12) {
                    DetailPanel("Device") {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                            secondaryStat("Vendor", device?.vendor ?? "—")
                            secondaryStat("Cores", device?.coreCount.map(String.init) ?? "—")
                            secondaryStat("Metal", device?.metalSupport ?? "—")
                            secondaryStat("VRAM", unifiedMemory)
                            secondaryStat("Allocated", monitor.snapshot.gpu.allocatedMemoryBytes.map(bytes) ?? "—")
                            secondaryStat("Display", device?.mainDisplayResolution ?? "—")
                            secondaryStat("Refresh", refreshRate)
                            secondaryStat("Power", monitor.snapshot.power.gpuPowerWatts.map { String(format: "%.1f W", $0) } ?? "—")
                        }
                    }
                    DetailPanel("Engine activity") {
                        ForEach(engineActivity, id: \.0) { engine, value in
                            HStack(spacing: 12) {
                                Text(engine).foregroundStyle(MoniPalette.foregroundSecondary).frame(width: 92, alignment: .leading)
                                GeometryReader { geometry in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(MoniPalette.track)
                                        Capsule()
                                            .fill(MoniPalette.green)
                                            .frame(width: geometry.size.width * min(1, max(0, (value ?? 0) / 100)))
                                    }
                                }
                                .frame(height: 6)
                                Text(value.map(percent) ?? "—").fontWeight(.bold).frame(width: 40, alignment: .trailing)
                            }
                            .font(.system(size: 12.5))
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)

                DetailPanel("GPU clients") {
                    if monitor.snapshot.gpu.clients.isEmpty {
                        Text("No active GPU clients")
                            .font(.system(size: 13))
                            .foregroundStyle(MoniPalette.foregroundTertiary)
                    } else {
                        VStack(spacing: 0) {
                            HStack(spacing: 10) {
                                Text("Client").frame(maxWidth: .infinity, alignment: .leading)
                                Text("PID").frame(width: 72, alignment: .trailing)
                                Text("Memory").frame(width: 100, alignment: .trailing)
                                Text("GPU").frame(width: 70, alignment: .trailing)
                            }
                            .padding(.bottom, 4)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(MoniPalette.foregroundSecondary)

                            ForEach(monitor.snapshot.gpu.clients.prefix(8)) { client in
                                HStack(spacing: 10) {
                                    Text(client.name)
                                        .fontWeight(.semibold)
                                        .lineLimit(1)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Text(client.pid.formatted())
                                        .foregroundStyle(MoniPalette.foregroundTertiary)
                                        .frame(width: 72, alignment: .trailing)
                                    Text(client.memoryBytes > 0 ? bytes(client.memoryBytes) : "—")
                                        .foregroundStyle(MoniPalette.foregroundSecondary)
                                        .frame(width: 100, alignment: .trailing)
                                    Text(percent(client.utilizationPercent))
                                        .fontWeight(.bold)
                                        .monospacedDigit()
                                        .frame(width: 70, alignment: .trailing)
                                        .moniNumericTransition(client.utilizationPercent)
                                }
                                .font(.system(size: 12.5))
                                .padding(.vertical, 6)
                            }
                        }
                    }
                }
            }
        }
    }

    private var engineActivity: [(String, Double?)] {
        [
            ("Overall", monitor.snapshot.gpu.utilizationPercent),
            ("Render", monitor.snapshot.gpu.rendererPercent),
            ("Tiler", monitor.snapshot.gpu.tilerPercent),
        ]
    }

    private var deviceSubtitle: String {
        guard let device else { return MoniLocalization.string("No Metal GPU") }
        var parts = [device.name]
        if let coreCount = device.coreCount {
            parts.append(MoniLocalization.format("%@ cores", coreCount.formatted()))
        }
        if let metalSupport = device.metalSupport { parts.append(metalSupport) }
        return parts.joined(separator: " · ")
    }

    private var unifiedMemory: String {
        guard let device else { return "—" }
        if let memory = device.unifiedMemoryBytes {
            return MoniLocalization.format("Unified %@", bytes(memory))
        }
        return MoniLocalization.string(device.hasUnifiedMemory ? "Unified" : "Dedicated")
    }

    private var refreshRate: String {
        guard let value = device?.mainDisplayRefreshRateHertz else { return "—" }
        return value.rounded() == value ? "\(Int(value)) Hz" : String(format: "%.1f Hz", value)
    }
}

private struct NetworkDetailView: View {
    @EnvironmentObject private var monitor: SystemMonitor
    @State private var historyRange = "1m"

    private var network: NetworkUsage { monitor.snapshot.network }
    private var activeInterface: NetworkInterfaceUsage? {
        network.primaryInterfaceName.flatMap { name in
            network.interfaces.first { $0.name == name }
        } ?? network.interfaces.first(where: \.isActive)
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 12) {
                DetailPanel {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("Network")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(MoniPalette.cyan)
                        Text(networkHeader)
                            .font(.system(size: 12.5))
                            .foregroundStyle(MoniPalette.foregroundTertiary)
                        Spacer(minLength: 12)
                        SecondaryRangePicker(selection: $historyRange)
                        Text("↓ " + rate(network.downloadBytesPerSecond))
                            .foregroundStyle(MoniPalette.cyan)
                        Text("↑ " + rate(network.uploadBytesPerSecond))
                            .foregroundStyle(MoniPalette.orange)
                    }
                    .font(.system(size: 20, weight: .bold))
                    .monospacedDigit()
                    InteractiveSparkline(
                        series: [
                            InteractiveSparklineSeries(
                                name: "Download",
                                values: monitor.history(.download, duration: secondaryHistoryDuration(historyRange)),
                                color: MoniPalette.cyan,
                                showsFill: true,
                                formatValue: rate
                            ),
                            InteractiveSparklineSeries(
                                name: "Upload",
                                values: monitor.history(.upload, duration: secondaryHistoryDuration(historyRange)),
                                color: MoniPalette.orange,
                                formatValue: rate
                            )
                        ],
                        dates: monitor.historyDates(.download, duration: secondaryHistoryDuration(historyRange))
                    )
                    .frame(height: 160)
                    rangeFooter(historyRange)
                }

                HStack(alignment: .top, spacing: 12) {
                    DetailPanel("Interfaces") {
                        ForEach(visibleInterfaces) { interface in
                            HStack(spacing: 10) {
                                Text(interface.name).fontWeight(.semibold).frame(width: 62, alignment: .leading)
                                Text(interfaceDetail(interface))
                                    .foregroundStyle(MoniPalette.foregroundTertiary)
                                    .lineLimit(1)
                                Spacer()
                                Text(MoniLocalization.string(interface.isActive ? "Active" : "Inactive"))
                                    .fontWeight(.bold)
                                    .foregroundStyle(interface.isActive ? MoniPalette.green : MoniPalette.foregroundSecondary)
                            }
                            .font(.system(size: 12.5))
                            .padding(.vertical, 8)
                        }
                    }
                    DetailPanel("Link & totals") {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                            secondaryStat("Public IP", publicIPAddress)
                            secondaryStat("Gateway", network.gateway ?? "Unavailable")
                            secondaryStat("Signal", network.wifi?.signalStrengthDBm.map { "\($0) dBm" } ?? "Unavailable")
                            secondaryStat("Channel", network.wifi?.channelDescription ?? "Unavailable")
                            secondaryStat(
                                "Link speed",
                                activeInterface.flatMap { $0.linkSpeedBitsPerSecond > 0 ? bitRate($0.linkSpeedBitsPerSecond) : nil } ?? "Unknown"
                            )
                            secondaryStat("IP lookup", ipLookupDuration)
                            secondaryStat("Received total", bytes(activeInterface?.receivedBytes ?? network.totalReceivedBytes))
                            secondaryStat("Sent total", bytes(activeInterface?.sentBytes ?? network.totalSentBytes))
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)

                DetailPanel("Active connections") {
                    HStack(spacing: 10) {
                        Text("Process").frame(maxWidth: .infinity, alignment: .leading)
                        Text("PID").frame(width: 64, alignment: .trailing)
                        Text("Local").frame(width: 170, alignment: .leading)
                        Text("Remote").frame(width: 190, alignment: .leading)
                        Text("Proto").frame(width: 58, alignment: .leading)
                        Text("In").frame(width: 78, alignment: .trailing)
                        Text("Out").frame(width: 78, alignment: .trailing)
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(MoniPalette.foregroundTertiary)

                    if network.connections.isEmpty {
                        Text("No active external connections")
                            .font(.system(size: 13))
                            .foregroundStyle(MoniPalette.foregroundTertiary)
                            .padding(.vertical, 8)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(network.connections) { connection in
                                HStack(spacing: 10) {
                                    Text(connection.processName)
                                        .fontWeight(.semibold)
                                        .lineLimit(1)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Text(connection.pid.formatted())
                                        .foregroundStyle(MoniPalette.foregroundTertiary)
                                        .frame(width: 64, alignment: .trailing)
                                    Text(connection.localEndpoint)
                                        .foregroundStyle(MoniPalette.foregroundTertiary)
                                        .lineLimit(1)
                                        .frame(width: 170, alignment: .leading)
                                    Text(connection.remoteEndpoint)
                                        .foregroundStyle(MoniPalette.foregroundSecondary)
                                        .lineLimit(1)
                                        .frame(width: 190, alignment: .leading)
                                    Text(connection.transport)
                                        .foregroundStyle(MoniPalette.foregroundTertiary)
                                        .frame(width: 58, alignment: .leading)
                                    Text(bytes(connection.receivedBytes))
                                        .foregroundStyle(MoniPalette.cyan)
                                        .frame(width: 78, alignment: .trailing)
                                    Text(bytes(connection.sentBytes))
                                        .foregroundStyle(MoniPalette.orange)
                                        .frame(width: 78, alignment: .trailing)
                                }
                                .font(.system(size: 12.5))
                                .monospacedDigit()
                                .padding(.vertical, 6)
                            }
                        }
                    }
                }
            }
        }
        .task {
            monitor.loadNetworkExternalDetailsIfNeeded()
        }
    }

    private var networkHeader: String {
        guard let activeInterface else { return MoniLocalization.string("No active interface") }
        var parts = [activeInterface.name]
        if let wifi = network.wifi, wifi.interfaceName == activeInterface.name {
            parts.append(wifi.physicalMode)
        } else {
            parts.append(activeInterface.kind)
        }
        if let address = activeInterface.address { parts.append(address) }
        if let publicIPAddress = monitor.publicIPAddress {
            parts.append(MoniLocalization.format("public %@", publicIPAddress))
        }
        return parts.joined(separator: " · ")
    }

    private var visibleInterfaces: [NetworkInterfaceUsage] {
        var result: [NetworkInterfaceUsage] = []
        func appendFirst(where predicate: (NetworkInterfaceUsage) -> Bool) {
            guard let interface = network.interfaces.first(where: predicate),
                  !result.contains(where: { $0.id == interface.id }) else { return }
            result.append(interface)
        }

        if let primaryName = network.primaryInterfaceName {
            appendFirst { $0.name == primaryName }
        }
        appendFirst { $0.name.hasPrefix("en") && $0.name != network.primaryInterfaceName }
        appendFirst { $0.name.hasPrefix("utun") && $0.isActive }
        appendFirst { $0.name == "bridge0" }
        for interface in network.interfaces where result.count < 4 {
            if interface.address != nil, !result.contains(where: { $0.id == interface.id }) {
                result.append(interface)
            }
        }
        return result
    }

    private func interfaceDetail(_ interface: NetworkInterfaceUsage) -> String {
        var parts = [interface.kind]
        if let address = interface.address { parts.append(address) }
        if let wifi = network.wifi,
           wifi.interfaceName == interface.name,
           let networkName = wifi.networkName {
            parts.append(networkName)
        } else if interface.address == nil {
            parts.append(MoniLocalization.string("no address"))
        }
        return parts.joined(separator: " · ")
    }

    private var publicIPAddress: String {
        monitor.publicIPAddress ?? MoniLocalization.string(monitor.isLoadingNetworkExternalDetails ? "Querying…" : "Unavailable")
    }

    private var ipLookupDuration: String {
        monitor.networkLatencyMilliseconds.map { "\(Int($0.rounded())) ms" }
            ?? (monitor.isLoadingNetworkExternalDetails ? "Looking up…" : "Unavailable")
    }
}

private struct StorageDetailView: View {
    @EnvironmentObject private var monitor: SystemMonitor
    @Binding var selection: MonitorSection

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 12) {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(monitor.snapshot.volumes) { volume in
                        DetailPanel {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(volume.name)
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(MoniPalette.orange)
                                Text(volume.mountPath)
                                    .font(.system(size: 12))
                                    .foregroundStyle(MoniPalette.foregroundTertiary)
                                    .lineLimit(1)
                                Spacer()
                                Text(percent(volume.usedPercent))
                                    .font(.system(size: 22, weight: .bold))
                                    .foregroundStyle(volume.usedPercent >= 90 ? MoniPalette.red : MoniPalette.orange)
                            }
                            ProgressView(value: volume.usedPercent, total: 100)
                                .tint(volume.usedPercent >= 90 ? MoniPalette.red : MoniPalette.orange)
                            Text("\(bytes(UInt64(volume.usedBytes))) of \(bytes(UInt64(volume.totalBytes))) used")
                                .font(.system(size: 12.5))
                                .foregroundStyle(MoniPalette.foregroundSecondary)
                            HStack(spacing: 14) {
                                secondaryStat("Format", volume.format ?? "Unknown")
                                secondaryStat("Free", bytes(UInt64(max(0, volume.availableBytes))))
                            }
                        }
                    }
                }

                DetailPanel {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("DISK ACTIVITY")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(MoniPalette.foregroundSecondary)
                            .tracking(0.7)
                        Spacer()
                        Text("Read \(rate(monitor.snapshot.diskActivity.readBytesPerSecond))")
                            .foregroundStyle(MoniPalette.cyan)
                        Text("Write \(rate(monitor.snapshot.diskActivity.writeBytesPerSecond))")
                            .foregroundStyle(MoniPalette.orange)
                    }
                    .font(.system(size: 15, weight: .bold))
                    InteractiveSparkline(
                        series: [
                            InteractiveSparklineSeries(
                                name: "Read",
                                values: monitor.diskReadHistory,
                                color: MoniPalette.cyan,
                                showsFill: true,
                                formatValue: rate
                            ),
                            InteractiveSparklineSeries(
                                name: "Write",
                                values: monitor.diskWriteHistory,
                                color: MoniPalette.orange,
                                formatValue: rate
                            )
                        ],
                        dates: monitor.recentHistoryDates
                    )
                        .frame(height: 120)
                }

                HStack(alignment: .top, spacing: 12) {
                    DetailPanel("Largest folders") {
                        if monitor.largestFolders.isEmpty, monitor.isScanningStorage {
                            HStack(spacing: 9) {
                                ProgressView().controlSize(.small)
                                Text("Calculating folder sizes…")
                                    .foregroundStyle(MoniPalette.foregroundTertiary)
                            }
                            .font(.system(size: 12.5))
                            .frame(maxWidth: .infinity, minHeight: 52, alignment: .center)
                        } else if monitor.largestFolders.isEmpty {
                            Text("Folder sizes unavailable")
                                .font(.system(size: 12.5))
                                .foregroundStyle(MoniPalette.foregroundTertiary)
                                .frame(maxWidth: .infinity, minHeight: 52, alignment: .center)
                        } else {
                            VStack(spacing: 0) {
                                HStack(spacing: 12) {
                                    Text("Folder").frame(width: 148, alignment: .leading)
                                    Text("Relative size").frame(maxWidth: .infinity, alignment: .leading)
                                    Text("Size").frame(width: 86, alignment: .trailing)
                                }
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(MoniPalette.foregroundSecondary)
                                .padding(.bottom, 4)

                                ForEach(monitor.largestFolders) { folder in
                                    HStack(spacing: 12) {
                                        Text(folder.path)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                            .frame(width: 148, alignment: .leading)
                                        GeometryReader { geometry in
                                            ZStack(alignment: .leading) {
                                                Capsule().fill(MoniPalette.track)
                                                Capsule()
                                                    .fill(MoniPalette.orange)
                                                    .frame(width: geometry.size.width * folderRatio(folder))
                                            }
                                        }
                                        .frame(height: 6)
                                        Text(bytes(folder.sizeBytes))
                                            .fontWeight(.bold)
                                            .monospacedDigit()
                                            .lineLimit(1)
                                            .minimumScaleFactor(0.8)
                                            .frame(width: 86, alignment: .trailing)
                                    }
                                    .font(.system(size: 12.5))
                                    .padding(.vertical, 6)
                                    .transition(MoniMotion.itemTransition)
                                }
                            }
                        }
                    }
                    DetailPanel("Drive health") {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                            secondaryStat("Model", driveHealth.model ?? "Reading…")
                            secondaryStat("S.M.A.R.T.", driveHealth.smartStatus ?? "Reading…")
                            secondaryStat("Temperature", driveTemperature)
                            secondaryStat("Written total", driveHealth.totalWrittenBytes.map(bytes) ?? "Reading…")
                            secondaryStat("IOPS", driveIOPS)
                            secondaryStat("TRIM", driveHealth.trimEnabled.map { $0 ? "Enabled" : "Disabled" } ?? "Reading…")
                        }
                        Button {
                            selection = .disks
                        } label: {
                            Text("Browse files ›")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 9)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(MoniPressButtonStyle())
                        .foregroundStyle(MoniPalette.blue)
                        .background(MoniPalette.control)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task {
            monitor.loadStorageFoldersIfNeeded()
        }
        .moniAnimation(value: monitor.largestFolders.map(\.id))
    }

    private var driveHealth: DriveHealth {
        monitor.snapshot.driveHealth
    }

    private var largestFolderSize: UInt64 {
        max(1, monitor.largestFolders.first?.sizeBytes ?? 1)
    }

    private func folderRatio(_ folder: StorageFolderUsage) -> Double {
        min(1, max(0, Double(folder.sizeBytes) / Double(largestFolderSize)))
    }

    private var driveTemperature: String {
        driveHealth.temperatureCelsius.map { String(format: "%.0f°C", $0) } ?? "Reading…"
    }

    private var driveIOPS: String {
        let activity = monitor.snapshot.diskActivity
        return "\(Int((activity.readOperationsPerSecond + activity.writeOperationsPerSecond).rounded())) / s"
    }
}

private struct PowerDetailView: View {
    @EnvironmentObject private var monitor: SystemMonitor

    private var power: PowerUsage { monitor.snapshot.power }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    DetailPanel {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("Battery").font(.system(size: 15, weight: .bold)).foregroundStyle(MoniPalette.yellow)
                            Text(powerSourceDescription)
                                .font(.system(size: 12.5)).foregroundStyle(MoniPalette.foregroundTertiary)
                        }
                        if let batteryPercent = power.batteryPercent {
                            Text(MoniLocalization.string(power.batteryPercent.map(percent) ?? "No Battery"))
                                .font(.system(size: 44, weight: .bold, design: .rounded))
                                .moniNumericTransition(power.batteryPercent)
                            ProgressView(value: batteryPercent, total: 100).tint(MoniPalette.green)
                        } else {
                            Text("No Battery").font(.system(size: 30, weight: .bold, design: .rounded))
                        }
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                            secondaryStat("Status", powerSourceDescription)
                            secondaryStat("Remaining", remainingTime)
                            secondaryStat("Voltage", power.voltageVolts.map { String(format: "%.2f V", $0) } ?? "—")
                            secondaryStat("Cycle count", power.cycleCount.map(String.init) ?? "—")
                            secondaryStat("Health", power.batteryHealth ?? "—")
                            secondaryStat("Current", power.currentAmps.map { String(format: "%.2f A", $0) } ?? "—")
                            secondaryStat("Temperature", power.batteryTemperatureCelsius.map { String(format: "%.1f°C", $0) } ?? "—")
                        }
                    }
                    DetailPanel {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("Thermals").font(.system(size: 15, weight: .bold)).foregroundStyle(MoniPalette.orange)
                            Text(MoniLocalization.string(power.cpuTemperatureCelsius == nil ? "Waiting for sensors" : "Live HID sensors"))
                                .font(.system(size: 12.5)).foregroundStyle(MoniPalette.foregroundTertiary)
                            Spacer()
                            Text(power.cpuTemperatureCelsius.map { String(format: "%.1f°C", $0) } ?? "—")
                                .font(.system(size: 22, weight: .bold))
                        }
                        InteractiveSparkline(
                            series: [
                                InteractiveSparklineSeries(
                                    name: "CPU",
                                    values: monitor.cpuTemperatureHistory,
                                    color: MoniPalette.orange,
                                    showsFill: true,
                                    formatValue: { String(format: "%.1f°C", $0) }
                                ),
                                InteractiveSparklineSeries(
                                    name: "GPU",
                                    values: monitor.gpuTemperatureHistory,
                                    color: MoniPalette.green,
                                    formatValue: { String(format: "%.1f°C", $0) }
                                )
                            ],
                            dates: monitor.cpuTemperatureHistoryDates
                        )
                            .frame(height: 108)
                        if power.fans.isEmpty {
                            secondaryStat("Fans", "No fan data")
                        } else {
                            HStack(spacing: 14) {
                                ForEach(power.fans.prefix(2)) { fan in
                                    secondaryStat(fan.name, String(format: "%.0f RPM", fan.revolutionsPerMinute))
                                }
                            }
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)

                DetailPanel("Temperature sensors") {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 8)],
                        spacing: 8
                    ) {
                        if let temperature = power.batteryTemperatureCelsius {
                            sensorStat("Battery", temperature)
                        }
                        ForEach(power.temperatureSensors) { sensor in
                            sensorStat(sensor.name, sensor.valueCelsius)
                        }
                    }
                }

                DetailPanel("Power draw") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 14) {
                        insetStat("System input", power.systemPowerWatts.map { String(format: "%.1f W", $0) } ?? "—")
                        insetStat("CPU package", power.cpuPowerWatts.map { String(format: "%.1f W", $0) } ?? "—")
                        insetStat("GPU", power.gpuPowerWatts.map { String(format: "%.1f W", $0) } ?? "—")
                        insetStat("Memory", power.memoryPowerWatts.map { String(format: "%.1f W", $0) } ?? "—")
                    }
                }
            }
        }
    }

    private var remainingTime: String {
        if power.batteryPercent ?? 0 >= 100 { return MoniLocalization.string("Fully charged") }
        guard let minutes = power.timeRemainingMinutes, minutes > 0 else {
            return MoniLocalization.string("Calculating remaining time")
        }
        return MoniLocalization.format("%@h %@m remaining", (minutes / 60).formatted(), (minutes % 60).formatted())
    }

    private var powerSourceDescription: String {
        if power.isCharging { return MoniLocalization.string("Charging") }
        if power.isExternalPowerConnected { return MoniLocalization.string("AC Power") }
        return MoniLocalization.string("On battery")
    }

    private func sensorStat(_ name: String, _ temperature: Double) -> some View {
        HStack(spacing: 8) {
            Text(name)
                .foregroundStyle(MoniPalette.foregroundSecondary)
                .lineLimit(1)
                .help(name)
            Spacer(minLength: 4)
            Text(String(format: "%.1f°C", temperature))
                .fontWeight(.bold)
                .monospacedDigit()
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(MoniPalette.inset)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

private struct DockerDetailView: View {
    @EnvironmentObject private var monitor: SystemMonitor
    @Binding var selection: MonitorSection

    private var docker: DockerStatus { monitor.snapshot.docker }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            DetailPanel {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Docker").font(.system(size: 17, weight: .bold)).foregroundStyle(MoniPalette.blue)
                    Text(MoniLocalization.string(docker.isRunning ? "Daemon reachable" : "Daemon not reachable"))
                        .font(.system(size: 12.5)).foregroundStyle(MoniPalette.foregroundTertiary)
                }
                if docker.isRunning {
                    containers
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: MonitorSection.docker.symbol)
                            .font(.system(size: 52, weight: .light))
                            .foregroundStyle(MoniPalette.foregroundQuaternary)
                        Text(MoniLocalization.string(docker.statusTitle))
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                        Text(MoniLocalization.string(docker.statusReason))
                            .font(.system(size: 13))
                            .foregroundStyle(MoniPalette.foregroundSecondary)
                            .multilineTextAlignment(.center)
                        Button("Back to summary") { selection = .summary }
                            .buttonStyle(.bordered)
                            .moniPointingHand()
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 52)
                }

                Divider()
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 12) {
                    dockerStat("Installed", docker.isInstalled ? "Yes" : "No")
                    dockerStat("Status", docker.statusTitle)
                    dockerStat("Provider", docker.installation ?? "—")
                    dockerStat("Socket", docker.socketPath ?? "—")
                    dockerStat("Detection", "Local")
                    dockerStat("Management", "Read only")
                }
            }
        }
        .moniAnimation(value: docker.containers.map(\.id))
    }

    @ViewBuilder
    private var containers: some View {
        HStack(spacing: 10) {
            Text("CONTAINERS")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(MoniPalette.foregroundSecondary)
                .tracking(0.7)
            Spacer()
            Text("\(docker.runningContainerCount) running · \(docker.containers.count) total")
                .font(.system(size: 12))
                .foregroundStyle(MoniPalette.foregroundTertiary)
                .monospacedDigit()
        }
        .padding(.top, 4)

        if docker.containers.isEmpty {
            Text("The engine is reachable but reports no containers.")
                .font(.system(size: 13))
                .foregroundStyle(MoniPalette.foregroundTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 22)
        } else {
            HStack(spacing: 10) {
                Text("Container").frame(maxWidth: .infinity, alignment: .leading)
                Text("Status").frame(width: 220, alignment: .trailing)
                Text("State").frame(width: 84, alignment: .trailing)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(MoniPalette.foregroundSecondary)

            VStack(spacing: 2) {
                ForEach(docker.containers) { container in
                    HStack(spacing: 10) {
                        HStack(spacing: 10) {
                            Circle()
                                .fill(containerColor(container.state))
                                .frame(width: 8, height: 8)
                            Text(container.name)
                                .fontWeight(.semibold)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text(container.status)
                            .foregroundStyle(MoniPalette.foregroundSecondary)
                            .lineLimit(1)
                            .frame(width: 220, alignment: .trailing)
                        Text(container.state.capitalized)
                            .fontWeight(.bold)
                            .foregroundStyle(containerColor(container.state))
                            .frame(width: 84, alignment: .trailing)
                    }
                    .font(.system(size: 12.5))
                    .padding(.vertical, 6)
                    .background(MoniPalette.inset)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
            }
        }
    }

    private func containerColor(_ state: String) -> Color {
        switch state {
        case "running": MoniPalette.green
        case "paused", "restarting", "created": MoniPalette.orange
        case "exited", "dead": MoniPalette.red
        default: MoniPalette.foregroundSecondary
        }
    }
}

private struct DiskBrowserView: View {
    struct FileItem: Identifiable, Sendable {
        let url: URL
        let isDirectory: Bool
        let size: UInt64
        let modified: Date?
        var id: String { url.path }
    }

    private struct LoadResult: Sendable {
        let items: [FileItem]
        let error: String?
    }

    @EnvironmentObject private var monitor: SystemMonitor
    @State private var selectedPath = "/"
    @State private var items: [FileItem] = []
    @State private var loadingPath: String?
    @State private var loadError: String?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text("VOLUMES")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(MoniPalette.foregroundTertiary)
                    .tracking(0.7)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)

                ForEach(monitor.snapshot.volumes) { volume in
                    Button {
                        selectedPath = volume.mountPath
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(volume.name)
                                    .font(.system(size: 13.5, weight: .semibold))
                                    .lineLimit(1)
                                Spacer()
                                Text(percent(volume.usedPercent))
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(volume.usedPercent >= 90 ? MoniPalette.red : MoniPalette.orange)
                            }
                            ProgressView(value: volume.usedPercent, total: 100)
                                .tint(volume.usedPercent >= 90 ? MoniPalette.red : MoniPalette.orange)
                            Text("\(bytes(UInt64(volume.usedBytes))) of \(bytes(UInt64(volume.totalBytes)))")
                                .font(.system(size: 12))
                                .foregroundStyle(MoniPalette.foregroundTertiary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 11)
                        .background(isWithin(volume) ? MoniPalette.selection : MoniPalette.insetSecondary)
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(isWithin(volume) ? MoniPalette.blue.opacity(0.5) : Color.clear, lineWidth: 1)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(MoniPressButtonStyle())
                }
                Spacer()
            }
            .frame(width: 250)

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Button {
                        let parent = URL(fileURLWithPath: selectedPath).deletingLastPathComponent().path
                        selectedPath = parent.isEmpty ? "/" : parent
                    } label: {
                        Image(systemName: "chevron.up")
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(MoniPressButtonStyle())
                    .disabled(isVolumeRoot)
                    Text(selectedPath)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Size").frame(width: 110, alignment: .trailing)
                    Text("Modified").frame(width: 130, alignment: .trailing)
                }
                .font(.system(size: 12))
                .foregroundStyle(MoniPalette.foregroundTertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                Divider()

                if let loadError {
                    ContentUnavailableView(
                        "Unable to read folder",
                        systemImage: "folder.badge.questionmark",
                        description: Text(loadError)
                    )
                    .transition(MoniMotion.itemTransition)
                } else if loadingPath == selectedPath {
                    HStack(spacing: 9) {
                        ProgressView().controlSize(.small)
                        Text("Reading folder…")
                            .foregroundStyle(MoniPalette.foregroundTertiary)
                    }
                    .font(.system(size: 12.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(MoniMotion.itemTransition)
                } else if items.isEmpty {
                    ContentUnavailableView(
                        "Empty folder",
                        systemImage: "folder",
                        description: Text("Nothing visible in this folder.")
                    )
                    .transition(MoniMotion.itemTransition)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(spacing: 2) {
                            ForEach(items) { item in
                                Button {
                                    if item.isDirectory { selectedPath = item.url.path }
                                } label: {
                                    HStack(spacing: 8) {
                                        HStack(spacing: 9) {
                                            RoundedRectangle(cornerRadius: 2)
                                                .fill(item.isDirectory ? MoniPalette.blue : MoniPalette.foregroundTertiary)
                                                .frame(width: 8, height: 8)
                                            Text(item.url.lastPathComponent).lineLimit(1)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        Text(item.isDirectory ? "—" : bytes(item.size))
                                            .foregroundStyle(MoniPalette.foregroundSecondary)
                                            .frame(width: 110, alignment: .trailing)
                                        Text(item.modified?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                                            .foregroundStyle(MoniPalette.foregroundTertiary)
                                            .frame(width: 130, alignment: .trailing)
                                    }
                                    .font(.system(size: 13))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 9)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(MoniPressButtonStyle(scale: 0.99))
                                .transition(MoniMotion.itemTransition)
                            }
                        }
                        .moniAnimation(value: items.map(\.id))
                    }
                }
            }
            .padding(6)
            .background(MoniPalette.insetSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(MoniPalette.line, lineWidth: 1)
            }
        }
        .moniAnimation(value: loadingPath)
        .moniAnimation(value: loadError)
        .task(id: selectedPath) {
            let requestedPath = selectedPath
            // Most folders list in a few milliseconds; flashing a spinner through
            // a cross-fade for those reads as flicker, so it only appears once a
            // read has been running long enough to feel slow. It is keyed by path
            // so a delayed spinner from an abandoned read cannot light up a newer
            // folder that has already finished.
            let spinner = Task {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled, selectedPath == requestedPath else { return }
                loadingPath = requestedPath
            }
            let result = await Task.detached(priority: .userInitiated) {
                Self.loadItems(at: requestedPath)
            }.value
            spinner.cancel()
            guard !Task.isCancelled, selectedPath == requestedPath else { return }
            items = result.items
            loadError = result.error
            loadingPath = nil
        }
    }

    private var isVolumeRoot: Bool {
        monitor.snapshot.volumes.contains { $0.mountPath == selectedPath }
    }

    private func isWithin(_ volume: VolumeUsage) -> Bool {
        selectedVolumeID == volume.id
    }

    private var selectedVolumeID: String? {
        monitor.snapshot.volumes
            .filter { volume in
                volume.mountPath == "/"
                    ? selectedPath.hasPrefix("/")
                    : selectedPath == volume.mountPath || selectedPath.hasPrefix(volume.mountPath + "/")
            }
            .max { $0.mountPath.count < $1.mountPath.count }?
            .id
    }

    private nonisolated static func loadItems(at path: String) -> LoadResult {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: path),
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            )
            let items = urls.compactMap { url -> FileItem? in
                guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
                return FileItem(
                    url: url,
                    isDirectory: values.isDirectory ?? false,
                    size: UInt64(max(0, values.fileSize ?? 0)),
                    modified: values.contentModificationDate
                )
            }
            .sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
            }
            return LoadResult(items: items, error: nil)
        } catch {
            return LoadResult(items: [], error: error.localizedDescription)
        }
    }
}

private struct SecondaryRangePicker: View {
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 4) {
            ForEach(["1m", "1h", "24h"], id: \.self) { range in
                Button {
                    selection = range
                } label: {
                    Text(range)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(
                            selection == range
                                ? MoniPalette.foreground
                                : MoniPalette.foregroundTertiary
                        )
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(selection == range ? MoniPalette.controlSelected : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(MoniPressButtonStyle(scale: 0.98))
            }
        }
    }
}

private func secondaryStat(_ key: String, _ text: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
        Text(MoniLocalization.string(key)).foregroundStyle(MoniPalette.foregroundSecondary)
        Text(MoniLocalization.string(text)).fontWeight(.bold).monospacedDigit().lineLimit(1)
    }
    .font(.system(size: 12.5))
    .frame(maxWidth: .infinity, alignment: .leading)
}

private func insetStat(_ key: String, _ text: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        Text(MoniLocalization.string(key)).font(.system(size: 12)).foregroundStyle(MoniPalette.foregroundSecondary)
        Text(MoniLocalization.string(text)).font(.system(size: 20, weight: .bold)).monospacedDigit()
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(MoniPalette.inset)
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
}

private func dockerStat(_ key: String, _ text: String) -> some View {
    HStack(spacing: 8) {
        Text(MoniLocalization.string(key)).foregroundStyle(MoniPalette.foregroundSecondary)
        Spacer(minLength: 6)
        Text(MoniLocalization.string(text)).fontWeight(.bold).lineLimit(1)
    }
    .font(.system(size: 12.5))
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .background(MoniPalette.inset)
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
}

private func rangeFooter(_ range: String) -> some View {
    HStack {
        Text(MoniLocalization.string(range == "1m" ? "-1 min" : range == "1h" ? "-1 hour" : "-24 hours"))
        Spacer()
        Text("now")
    }
    .font(.system(size: 11.5))
    .foregroundStyle(MoniPalette.foregroundQuaternary)
}

private func secondaryHistoryDuration(_ range: String) -> TimeInterval {
    switch range {
    case "1h": 3_600
    case "24h": 86_400
    default: 60
    }
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

private func bitRate(_ value: UInt64) -> String {
    let units = ["bps", "Kbps", "Mbps", "Gbps"]
    var amount = Double(value)
    var index = 0
    while amount >= 1_000, index < units.count - 1 {
        amount /= 1_000
        index += 1
    }
    let format = amount >= 100 || amount.rounded() == amount ? "%.0f %@" : "%.1f %@"
    return String(format: format, amount, units[index])
}
