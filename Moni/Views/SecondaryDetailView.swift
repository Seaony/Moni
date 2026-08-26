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
            DockerDetailView()
        case .disks:
            DiskBrowserView()
        default:
            EmptyView()
        }
    }
}

private struct GPUDetailView: View {
    @EnvironmentObject private var monitor: SystemMonitor

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 12) {
                DetailPanel("GPU") {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(monitor.snapshot.gpuDevices.first?.name ?? "No Metal GPU")
                                .font(.title2.bold())
                                .foregroundStyle(.green)
                            Text("Utilization")
                                .foregroundStyle(.secondary)
                            Text("No Data")
                                .font(.system(size: 36, weight: .bold, design: .rounded))
                        }
                        Spacer()
                        Image(systemName: "display")
                            .font(.system(size: 56))
                            .foregroundStyle(.green.opacity(0.6))
                    }
                    Text("macOS does not provide GPU utilization through a public API. Device capabilities below come from Metal.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ForEach(monitor.snapshot.gpuDevices) { device in
                    DetailPanel(device.name) {
                        value("Registry ID", String(device.registryID))
                        value("Unified memory", device.hasUnifiedMemory ? "Yes" : "No")
                        value("Low power", device.isLowPower ? "Yes" : "No")
                        value("Removable", device.isRemovable ? "Yes" : "No")
                        value("Recommended working set", bytes(device.recommendedMaxWorkingSetSize))
                    }
                    .transition(MoniMotion.itemTransition)
                }
            }
            .moniAnimation(value: monitor.snapshot.gpuDevices.map(\.id))
        }
    }
}

private struct NetworkDetailView: View {
    @EnvironmentObject private var monitor: SystemMonitor

    private var network: NetworkUsage { monitor.snapshot.network }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 12) {
                DetailPanel("Network") {
                    HStack(alignment: .bottom, spacing: 28) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("↓ Download")
                                .foregroundStyle(.cyan)
                            Text(rate(network.downloadBytesPerSecond))
                                .font(.system(size: 29, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .moniNumericTransition(network.downloadBytesPerSecond)
                            Text("↑ Upload")
                                .foregroundStyle(.orange)
                            Text(rate(network.uploadBytesPerSecond))
                                .font(.system(size: 29, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .moniNumericTransition(network.uploadBytesPerSecond)
                        }
                        VStack(spacing: 3) {
                            Sparkline(values: monitor.downloadHistory, color: .cyan)
                            Sparkline(values: monitor.uploadHistory, color: .orange)
                        }
                        .frame(height: 160)
                    }
                    HStack {
                        MetricRow(label: "Received", value: bytes(network.totalReceivedBytes), color: .cyan)
                        MetricRow(label: "Sent", value: bytes(network.totalSentBytes), color: .orange)
                    }
                }

                DetailPanel("Interfaces") {
                    ForEach(network.interfaces) { interface in
                        HStack(spacing: 10) {
                            Circle()
                                .fill(interface.isActive ? Color.green : Color.secondary.opacity(0.35))
                                .frame(width: 8, height: 8)
                            Text(interface.name)
                                .fontWeight(.semibold)
                                .frame(width: 90, alignment: .leading)
                            Text(interface.isActive ? "Active" : "Inactive")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("↓ \(bytes(interface.receivedBytes))")
                                .foregroundStyle(.cyan)
                            Text("↑ \(bytes(interface.sentBytes))")
                                .foregroundStyle(.orange)
                        }
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .padding(.vertical, 4)
                        .transition(MoniMotion.itemTransition)
                    }
                }
                .moniAnimation(value: network.interfaces.map(\.id))
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
                ForEach(monitor.snapshot.volumes) { volume in
                    DetailPanel(volume.name) {
                        HStack {
                            Text(volume.mountPath)
                                .fontWeight(.semibold)
                            Spacer()
                            Text(percent(volume.usedPercent))
                                .font(.title3.bold())
                                .foregroundStyle(volume.usedPercent >= 90 ? .red : .orange)
                                .moniNumericTransition(volume.usedPercent)
                        }
                        ProgressView(value: volume.usedPercent, total: 100)
                            .tint(volume.usedPercent >= 90 ? .red : .orange)
                            .moniAnimation(MoniMotion.data, value: volume.usedPercent)
                        HStack {
                            Text("Used \(bytes(UInt64(volume.usedBytes)))")
                            Spacer()
                            Text("Available \(bytes(UInt64(max(0, volume.availableBytes))))")
                            Spacer()
                            Text("Total \(bytes(UInt64(volume.totalBytes)))")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .transition(MoniMotion.itemTransition)
                }

                Button {
                    selection = .disks
                } label: {
                    Label("Browse mounted volumes", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                        .padding(10)
                }
                .buttonStyle(.borderedProminent)
            }
            .moniAnimation(value: monitor.snapshot.volumes.map(\.id))
        }
    }
}

private struct PowerDetailView: View {
    @EnvironmentObject private var monitor: SystemMonitor

    private var power: PowerUsage { monitor.snapshot.power }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 12) {
                DetailPanel("Battery") {
                    HStack(alignment: .center, spacing: 24) {
                        Image(systemName: power.isCharging ? "battery.100percent.bolt" : "battery.75percent")
                            .font(.system(size: 54))
                            .foregroundStyle(power.isCharging ? .green : .yellow)
                            .id(power.isCharging)
                            .transition(MoniMotion.itemTransition)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(power.batteryPercent.map(percent) ?? "No Battery")
                                .font(.system(size: 38, weight: .bold, design: .rounded))
                                .moniNumericTransition(power.batteryPercent)
                            Text(power.isCharging ? "Charging on AC power" : remainingTime)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .moniAnimation(value: power.isCharging)
                }

                DetailPanel("Sensors") {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("CPU die")
                                .foregroundStyle(.secondary)
                            Text("No Data")
                                .font(.title.bold())
                        }
                        Spacer()
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Fan speed")
                                .foregroundStyle(.secondary)
                            Text("No Data")
                                .font(.title.bold())
                        }
                    }
                    Text("Temperature and fan telemetry require hardware interfaces that are not part of the public macOS API.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

    private var docker: DockerStatus { monitor.snapshot.docker }

    var body: some View {
        DetailPanel("Docker") {
            HStack(spacing: 20) {
                Image(systemName: "shippingbox")
                    .font(.system(size: 52))
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 5) {
                    Text(docker.statusTitle)
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .id(docker.statusTitle)
                        .transition(MoniMotion.itemTransition)
                    Text(docker.installation ?? "No supported installation")
                        .foregroundStyle(.secondary)
                }
            }
            Divider()
            value("Installed", docker.isInstalled ? "Yes" : "No")
            value("Engine socket", docker.socketPath ?? "Not found")
            value("Status", docker.isRunning ? "Local socket available" : "Engine unavailable")
            Text(docker.statusReason)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Moni checks only local installation and engine socket state; it does not start or modify Docker.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .moniAnimation(value: docker.statusTitle)
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
        VStack(spacing: 10) {
            HStack {
                Picker("Volume", selection: $selectedPath) {
                    ForEach(monitor.snapshot.volumes) { volume in
                        Text(volume.name).tag(volume.mountPath)
                    }
                }
                .frame(width: 220)
                Button {
                    let parent = URL(fileURLWithPath: selectedPath).deletingLastPathComponent().path
                    selectedPath = parent.isEmpty ? "/" : parent
                } label: {
                    Image(systemName: "arrow.up")
                }
                .disabled(selectedPath == "/" || monitor.snapshot.volumes.contains { $0.mountPath == selectedPath })
                Text(selectedPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .transition(MoniMotion.itemTransition)
                } else {
                    Text("\(items.count) items")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .moniNumericTransition(items.count)
                        .transition(MoniMotion.itemTransition)
                }
            }

            DetailPanel("Disk browser") {
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
                                    HStack(spacing: 10) {
                                        Image(systemName: item.isDirectory ? "folder.fill" : "doc")
                                            .foregroundStyle(item.isDirectory ? .blue : .secondary)
                                        Text(item.url.lastPathComponent)
                                            .lineLimit(1)
                                        Spacer()
                                        Text(item.isDirectory ? "—" : bytes(item.size))
                                            .foregroundStyle(.secondary)
                                            .frame(width: 90, alignment: .trailing)
                                        Text(item.modified?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                                            .foregroundStyle(.tertiary)
                                            .frame(width: 145, alignment: .trailing)
                                    }
                                    .font(.system(size: 12))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
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

private func value(_ key: String, _ text: String) -> some View {
    HStack {
        Text(key).foregroundStyle(.secondary)
        Spacer()
        Text(text)
            .fontWeight(.semibold)
            .monospacedDigit()
            .moniNumericTransition(text)
    }
    .font(.system(size: 12.5))
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
