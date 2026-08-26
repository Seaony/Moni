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
                        Text(device?.name ?? "No Metal GPU")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.tertiary)
                        Spacer(minLength: 12)
                        SecondaryRangePicker(selection: $historyRange)
                        Text(monitor.snapshot.gpu.utilizationPercent.map(percent) ?? "No Data")
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                    }
                    Sparkline(values: Array(monitor.gpuHistory.suffix(secondarySampleCount(historyRange))), color: MoniPalette.green)
                        .frame(height: 160)
                    rangeFooter(historyRange)
                }

                HStack(alignment: .top, spacing: 12) {
                    DetailPanel("Device") {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                            secondaryStat("Name", device?.name ?? "—")
                            secondaryStat("Registry ID", device.map { String($0.registryID) } ?? "—")
                            secondaryStat("Unified memory", device.map { $0.hasUnifiedMemory ? "Yes" : "No" } ?? "—")
                            secondaryStat("Low power", device.map { $0.isLowPower ? "Yes" : "No" } ?? "—")
                            secondaryStat("Removable", device.map { $0.isRemovable ? "Yes" : "No" } ?? "—")
                            secondaryStat("Working set", device.map { bytes($0.recommendedMaxWorkingSetSize) } ?? "—")
                        }
                    }
                    DetailPanel("Engine activity") {
                        ForEach(engineActivity, id: \.0) { engine, value in
                            HStack(spacing: 12) {
                                Text(engine).foregroundStyle(.secondary).frame(width: 92, alignment: .leading)
                                ProgressView(value: value ?? 0, total: 100).tint(MoniPalette.green)
                                Text(value.map(percent) ?? "—").fontWeight(.bold).frame(width: 40, alignment: .trailing)
                            }
                            .font(.system(size: 12.5))
                        }
                        if let memory = monitor.snapshot.gpu.allocatedMemoryBytes {
                            secondaryStat("Allocated memory", bytes(memory))
                        }
                    }
                }

                DetailPanel("GPU clients") {
                    unavailableRow("The driver exposes cumulative client GPU time, but not a stable per-process utilization percentage.")
                }
            }
        }
    }

    private var engineActivity: [(String, Double?)] {
        [
            ("Renderer", monitor.snapshot.gpu.rendererPercent),
            ("Tiler", monitor.snapshot.gpu.tilerPercent),
        ]
    }
}

private struct NetworkDetailView: View {
    @EnvironmentObject private var monitor: SystemMonitor
    @State private var historyRange = "1m"

    private var network: NetworkUsage { monitor.snapshot.network }
    private var activeInterface: NetworkInterfaceUsage? { network.interfaces.first(where: \.isActive) }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 12) {
                DetailPanel {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("Network")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(MoniPalette.cyan)
                        Text(activeInterface.map { "\($0.name) · active" } ?? "No active interface")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.tertiary)
                        Spacer(minLength: 12)
                        SecondaryRangePicker(selection: $historyRange)
                        Text("↓ " + rate(network.downloadBytesPerSecond))
                            .foregroundStyle(MoniPalette.cyan)
                        Text("↑ " + rate(network.uploadBytesPerSecond))
                            .foregroundStyle(MoniPalette.orange)
                    }
                    .font(.system(size: 20, weight: .bold))
                    .monospacedDigit()
                    ZStack {
                        Sparkline(values: Array(monitor.downloadHistory.suffix(secondarySampleCount(historyRange))), color: MoniPalette.cyan)
                        Sparkline(values: Array(monitor.uploadHistory.suffix(secondarySampleCount(historyRange))), color: MoniPalette.orange)
                    }
                    .frame(height: 160)
                    rangeFooter(historyRange)
                }

                HStack(alignment: .top, spacing: 12) {
                    DetailPanel("Interfaces") {
                        ForEach(network.interfaces) { interface in
                            HStack(spacing: 10) {
                                Text(interface.name).fontWeight(.semibold).frame(width: 62, alignment: .leading)
                                Text("↓ \(bytes(interface.receivedBytes)) · ↑ \(bytes(interface.sentBytes))")
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                Spacer()
                                Text(interface.isActive ? "Active" : "Inactive")
                                    .fontWeight(.bold)
                                    .foregroundStyle(interface.isActive ? MoniPalette.green : MoniPalette.foregroundSecondary)
                            }
                            .font(.system(size: 12.5))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 8)
                        }
                    }
                    DetailPanel("Link & totals") {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                            secondaryStat("Download", rate(network.downloadBytesPerSecond))
                            secondaryStat("Upload", rate(network.uploadBytesPerSecond))
                            secondaryStat("Received", bytes(network.totalReceivedBytes))
                            secondaryStat("Sent", bytes(network.totalSentBytes))
                            secondaryStat("Interfaces", network.interfaces.count.formatted())
                            secondaryStat("Active", network.interfaces.filter(\.isActive).count.formatted())
                            secondaryStat(
                                "Link speed",
                                activeInterface.flatMap { $0.linkSpeedBitsPerSecond > 0 ? bitRate($0.linkSpeedBitsPerSecond) : nil } ?? "Unknown"
                            )
                            secondaryStat("Public IP", "Not queried")
                        }
                    }
                }

                DetailPanel("Active connections") {
                    unavailableRow("Connection ownership is not collected by Moni.")
                }
            }
        }
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
                                    .foregroundStyle(.tertiary)
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
                                .foregroundStyle(.secondary)
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
                            .foregroundStyle(.secondary)
                            .tracking(0.7)
                        Spacer()
                        Text("Read \(rate(monitor.snapshot.diskActivity.readBytesPerSecond))")
                            .foregroundStyle(MoniPalette.cyan)
                        Text("Write \(rate(monitor.snapshot.diskActivity.writeBytesPerSecond))")
                            .foregroundStyle(MoniPalette.orange)
                    }
                    .font(.system(size: 15, weight: .bold))
                    Sparkline(values: monitor.diskReadHistory, color: MoniPalette.cyan)
                        .frame(height: 120)
                }

                HStack(alignment: .top, spacing: 12) {
                    DetailPanel("Largest folders") {
                        unavailableRow("Open the disk browser to inspect folders.")
                    }
                    DetailPanel("Drive health") {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                            secondaryStat("Volumes", monitor.snapshot.volumes.count.formatted())
                            secondaryStat("Capacity", totalCapacity)
                            secondaryStat("Available", totalAvailable)
                            secondaryStat("SMART status", "—")
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
            }
        }
    }

    private var totalCapacity: String {
        bytes(UInt64(max(0, monitor.snapshot.volumes.reduce(Int64(0)) { $0 + $1.totalBytes })))
    }

    private var totalAvailable: String {
        bytes(UInt64(max(0, monitor.snapshot.volumes.reduce(Int64(0)) { $0 + $1.availableBytes })))
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
                            Text(power.isCharging ? "Charging" : "On battery")
                                .font(.system(size: 12.5)).foregroundStyle(.tertiary)
                        }
                        if let batteryPercent = power.batteryPercent {
                            Text(power.batteryPercent.map(percent) ?? "No Battery")
                                .font(.system(size: 44, weight: .bold, design: .rounded))
                                .moniNumericTransition(power.batteryPercent)
                            ProgressView(value: batteryPercent, total: 100).tint(MoniPalette.green)
                        } else {
                            Text("No Battery").font(.system(size: 30, weight: .bold, design: .rounded))
                        }
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                            secondaryStat("Status", power.isCharging ? "Charging" : "Discharging")
                            secondaryStat("Remaining", remainingTime)
                            secondaryStat("Voltage", power.voltageVolts.map { String(format: "%.2f V", $0) } ?? "—")
                            secondaryStat("Cycle count", power.cycleCount.map(String.init) ?? "—")
                            secondaryStat("Current", power.currentAmps.map { String(format: "%.2f A", $0) } ?? "—")
                            secondaryStat("Temperature", power.batteryTemperatureCelsius.map { String(format: "%.1f°C", $0) } ?? "—")
                        }
                    }
                    DetailPanel {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("Thermals").font(.system(size: 15, weight: .bold)).foregroundStyle(MoniPalette.orange)
                            Text(power.batteryTemperatureCelsius == nil ? "Not available" : "Battery sensor")
                                .font(.system(size: 12.5)).foregroundStyle(.tertiary)
                            Spacer()
                            Text(power.batteryTemperatureCelsius.map { String(format: "%.1f°C", $0) } ?? "—")
                                .font(.system(size: 22, weight: .bold))
                        }
                        unavailableChart("CPU/GPU die and fan telemetry require an undocumented HID/SMC backend.")
                            .frame(height: 108)
                        HStack(spacing: 14) {
                            secondaryStat("Fan 1", "—")
                            secondaryStat("Fan 2", "—")
                        }
                    }
                }

                DetailPanel("Temperature sensors") {
                    if let temperature = power.batteryTemperatureCelsius {
                        secondaryStat("Battery", String(format: "%.1f°C", temperature))
                    }
                    unavailableRow("CPU/GPU die sensors are not exposed through a stable documented API; the private HID/SMC backend is not enabled.")
                }

                DetailPanel("Power draw") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 14) {
                        insetStat("System input", power.systemPowerWatts.map { String(format: "%.1f W", $0) } ?? "—")
                        insetStat("CPU package", "—")
                        insetStat("GPU", "—")
                        insetStat("Battery", power.currentAmps.map { String(format: "%.2f A", $0) } ?? "—")
                    }
                }
            }
        }
    }

    private var remainingTime: String {
        if power.batteryPercent ?? 0 >= 100 { return "Fully charged" }
        guard let minutes = power.timeRemainingMinutes, minutes > 0 else { return "Calculating remaining time" }
        return "\(minutes / 60)h \(minutes % 60)m remaining"
    }
}

private struct DockerDetailView: View {
    @EnvironmentObject private var monitor: SystemMonitor
    @Binding var selection: MonitorSection

    private var docker: DockerStatus { monitor.snapshot.docker }

    var body: some View {
        DetailPanel {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Docker").font(.system(size: 17, weight: .bold)).foregroundStyle(MoniPalette.blue)
                Text(docker.isRunning ? "Daemon reachable" : "Daemon not reachable")
                    .font(.system(size: 12.5)).foregroundStyle(.tertiary)
            }
            VStack(spacing: 10) {
                Image(systemName: "shippingbox")
                    .font(.system(size: 52, weight: .light))
                    .foregroundStyle(docker.isRunning ? MoniPalette.blue : MoniPalette.foregroundQuaternary)
                Text(docker.statusTitle)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text(docker.statusReason)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Back to summary") { selection = .summary }
                    .buttonStyle(.bordered)
                    .moniPointingHand()
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 52)

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
    @State private var isLoading = false
    @State private var loadError: String?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text("VOLUMES")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.tertiary)
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
                                .foregroundStyle(.tertiary)
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
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                Divider()

                if let loadError {
                    ContentUnavailableView(
                        "Unable to read folder",
                        systemImage: "folder.badge.questionmark",
                        description: Text(loadError)
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
                                            .foregroundStyle(.secondary)
                                            .frame(width: 110, alignment: .trailing)
                                        Text(item.modified?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                                            .foregroundStyle(.tertiary)
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
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(MoniPalette.line, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .moniAnimation(value: isLoading)
        .moniAnimation(value: loadError)
        .task(id: selectedPath) {
            isLoading = true
            let requestedPath = selectedPath
            let result = await Task.detached(priority: .userInitiated) {
                Self.loadItems(at: requestedPath)
            }.value
            guard !Task.isCancelled, selectedPath == requestedPath else { return }
            items = result.items
            loadError = result.error
            isLoading = false
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
                Button(range) { selection = range }
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(selection == range ? .primary : .tertiary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(selection == range ? MoniPalette.controlSelected : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .buttonStyle(MoniPressButtonStyle(scale: 0.98))
            }
        }
    }
}

private func secondaryStat(_ key: String, _ text: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
        Text(key).foregroundStyle(.secondary)
        Text(text).fontWeight(.bold).monospacedDigit().lineLimit(1)
    }
    .font(.system(size: 12.5))
    .frame(maxWidth: .infinity, alignment: .leading)
}

private func insetStat(_ key: String, _ text: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        Text(key).font(.system(size: 12)).foregroundStyle(.secondary)
        Text(text).font(.system(size: 20, weight: .bold)).monospacedDigit()
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(MoniPalette.inset)
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
}

private func dockerStat(_ key: String, _ text: String) -> some View {
    HStack(spacing: 8) {
        Text(key).foregroundStyle(.secondary)
        Spacer(minLength: 6)
        Text(text).fontWeight(.bold).lineLimit(1)
    }
    .font(.system(size: 12.5))
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .background(MoniPalette.inset)
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
}

private func unavailableChart(_ message: String) -> some View {
    ZStack {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(MoniPalette.insetSecondary)
        Text(message)
            .font(.system(size: 12.5))
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .padding()
    }
}

private func unavailableRow(_ message: String) -> some View {
    Text(message)
        .font(.system(size: 12.5))
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .center)
}

private func rangeFooter(_ range: String) -> some View {
    HStack {
        Text(range == "1m" ? "-1 min" : range == "1h" ? "-1 hour" : "-24 hours")
        Spacer()
        Text("now")
    }
    .font(.system(size: 11.5))
    .foregroundStyle(.quaternary)
}

private func secondarySampleCount(_ range: String) -> Int {
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
