import Foundation
import WidgetKit

actor WidgetSnapshotWriter {
    static let shared = WidgetSnapshotWriter()

    private static let reloadInterval: TimeInterval = 5 * 60

    private var lastSystemWrite = Date.distantPast
    private var lastTimelineReload = Date.distantPast

    func persistSystem(_ snapshot: WidgetSystemSnapshot) {
        guard snapshot.date.timeIntervalSince(lastSystemWrite) >= 15 else { return }
        lastSystemWrite = snapshot.date
        try? MoniWidgetStorage.saveSystem(snapshot)
        reloadTimelinesIfDue(at: snapshot.date)
    }

    func persistAI(_ snapshot: WidgetAISnapshot) {
        try? MoniWidgetStorage.saveAI(snapshot)
        reloadTimelinesIfDue(at: Date())
    }

    /// WidgetKit budgets timeline reloads per day; a scan publishes twice and the
    /// AI screen rescans on every range change, so reloading on each write burns
    /// through the budget and leaves the widgets frozen.
    private func reloadTimelinesIfDue(at date: Date) {
        guard date.timeIntervalSince(lastTimelineReload) >= Self.reloadInterval else { return }
        lastTimelineReload = date
        WidgetCenter.shared.reloadAllTimelines()
    }
}

extension WidgetSystemSnapshot {
    init(
        snapshot: SystemSnapshot,
        histories: Histories,
        publicIPAddress: String?,
        networkLatencyMilliseconds: Double?,
        storageFolders: [StorageFolderUsage]
    ) {
        let root = snapshot.volumes.first { $0.mountPath == "/" }
        self.init(
            date: snapshot.date,
            hostName: snapshot.host.name,
            uptime: snapshot.host.uptime,
            loadAverages: snapshot.host.loadAverages,
            cpu: CPU(total: snapshot.cpu.total, user: snapshot.cpu.user, system: snapshot.cpu.system, perCore: snapshot.cpu.perCore),
            memory: Memory(totalBytes: snapshot.memory.totalBytes, usedBytes: snapshot.memory.usedBytes, freeBytes: snapshot.memory.freeBytes, wiredBytes: snapshot.memory.wiredBytes, compressedBytes: snapshot.memory.compressedBytes, swapUsedBytes: snapshot.memory.swapUsedBytes, pageIns: snapshot.memory.pageIns),
            volume: root.map { Volume(name: $0.name, totalBytes: $0.totalBytes, availableBytes: $0.availableBytes) },
            diskReadBytesPerSecond: snapshot.diskActivity.readBytesPerSecond,
            diskWriteBytesPerSecond: snapshot.diskActivity.writeBytesPerSecond,
            diskReadOperationsPerSecond: snapshot.diskActivity.readOperationsPerSecond,
            diskWriteOperationsPerSecond: snapshot.diskActivity.writeOperationsPerSecond,
            driveModel: snapshot.driveHealth.model,
            driveSmartStatus: snapshot.driveHealth.smartStatus,
            driveTemperatureCelsius: snapshot.driveHealth.temperatureCelsius,
            network: Network(
                downloadBytesPerSecond: snapshot.network.downloadBytesPerSecond,
                uploadBytesPerSecond: snapshot.network.uploadBytesPerSecond,
                interfaceName: snapshot.network.primaryInterfaceName,
                networkName: snapshot.network.wifi?.networkName,
                physicalMode: snapshot.network.wifi?.physicalMode,
                signalStrengthDBm: snapshot.network.wifi?.signalStrengthDBm,
                channel: snapshot.network.wifi?.channelDescription,
                transmitRateBitsPerSecond: snapshot.network.wifi?.transmitRateBitsPerSecond,
                publicIPAddress: publicIPAddress,
                latencyMilliseconds: networkLatencyMilliseconds,
                interfaces: snapshot.network.interfaces.prefix(4).map {
                    .init(name: $0.name, kind: $0.kind, address: $0.address, isActive: $0.isActive, linkSpeedBitsPerSecond: $0.linkSpeedBitsPerSecond)
                }
            ),
            processCount: snapshot.processes.count,
            threadCount: snapshot.processes.reduce(0) { $0 + $1.threadCount },
            processes: snapshot.processes.prefix(8).map { Process(name: $0.name, cpuPercent: $0.cpuPercent, memoryBytes: $0.memoryBytes, threadCount: $0.threadCount) },
            sensors: snapshot.power.temperatureSensors.prefix(8).map { Sensor(name: $0.name, celsius: $0.valueCelsius) },
            power: Power(
                batteryPercent: snapshot.power.batteryPercent,
                isCharging: snapshot.power.isCharging,
                batteryTemperatureCelsius: snapshot.power.batteryTemperatureCelsius,
                cycleCount: snapshot.power.cycleCount,
                batteryHealth: snapshot.power.batteryHealth,
                systemPowerWatts: snapshot.power.systemPowerWatts,
                cpuTemperatureCelsius: snapshot.power.cpuTemperatureCelsius,
                gpuTemperatureCelsius: snapshot.power.gpuTemperatureCelsius,
                fanRPM: snapshot.power.fans.first?.revolutionsPerMinute
            ),
            gpu: GPU(
                name: snapshot.gpuDevices.first?.name,
                coreCount: snapshot.gpuDevices.first?.coreCount,
                utilizationPercent: snapshot.gpu.utilizationPercent,
                rendererPercent: snapshot.gpu.rendererPercent,
                tilerPercent: snapshot.gpu.tilerPercent,
                allocatedMemoryBytes: snapshot.gpu.allocatedMemoryBytes,
                powerWatts: snapshot.power.gpuPowerWatts
            ),
            docker: Docker(
                isInstalled: snapshot.docker.isInstalled,
                isRunning: snapshot.docker.isRunning,
                installation: snapshot.docker.installation,
                socketPath: snapshot.docker.socketPath,
                containers: snapshot.docker.containers.prefix(8).map {
                    .init(name: $0.name, state: $0.state, status: $0.status)
                }
            ),
            histories: histories,
            alerts: Self.alerts(for: snapshot),
            storageItems: storageFolders.prefix(5).map {
                .init(name: URL(fileURLWithPath: $0.path).lastPathComponent, bytes: $0.sizeBytes)
            }
        )
    }

    /// Mirrors the thresholds the user configured in Settings → Alerts so the
    /// widget does not contradict the notifications.
    private static func alerts(for snapshot: SystemSnapshot) -> [Alert] {
        var alerts: [Alert] = []
        let cpuLimit = threshold(PreferenceKey.cpuAlertThreshold, fallback: 85)
        let memoryLimit = threshold(PreferenceKey.memoryAlertThreshold, fallback: 90)
        let diskLimit = threshold(PreferenceKey.diskAlertThreshold, fallback: 90)
        let temperatureLimit = threshold(PreferenceKey.temperatureAlertThreshold, fallback: 80)

        if snapshot.cpu.total >= cpuLimit {
            alerts.append(.init(message: "CPU usage is above \(Int(cpuLimit))%", date: snapshot.date, severity: 2))
        }
        if snapshot.memory.usedPercent >= memoryLimit {
            alerts.append(.init(message: "Memory usage is above \(Int(memoryLimit))%", date: snapshot.date, severity: 2))
        }
        if let temperature = snapshot.power.cpuTemperatureCelsius, temperature >= temperatureLimit {
            alerts.append(.init(message: "CPU temperature is above \(Int(temperatureLimit))°C", date: snapshot.date, severity: 2))
        }
        if let disk = snapshot.volumes.first(where: { $0.mountPath == "/" }), disk.usedPercent >= diskLimit {
            alerts.append(.init(message: "System disk usage is above \(Int(diskLimit))%", date: snapshot.date, severity: 3))
        }
        return alerts
    }

    private static func threshold(_ key: String, fallback: Double) -> Double {
        let value = UserDefaults.standard.double(forKey: key)
        return value == 0 ? fallback : value
    }
}

extension WidgetAISnapshot {
    init(summary: AIUsageSummary) {
        self.init(
            date: summary.scannedAt ?? .now,
            totalTokens: summary.totalTokens,
            estimatedCostUSD: summary.estimatedCostUSD,
            providers: summary.providers.map { provider in
                WidgetAIProvider(
                    name: provider.provider,
                    plan: provider.planName,
                    totalTokens: provider.totalTokens,
                    estimatedCostUSD: provider.estimatedCostUSD,
                    cacheHitPercent: provider.cacheHitPercent,
                    quotas: provider.quotaWindows
                        .filter { !$0.label.localizedCaseInsensitiveContains("code review") }
                        .map { quota in
                            .init(label: quota.label, remainingPercent: quota.remainingPercent, resetsAt: quota.resetsAt)
                        }
                )
            },
            daily: summary.daily.map { .init(date: $0.date, tokens: $0.tokens, costUSD: $0.costUSD) }
        )
    }
}
