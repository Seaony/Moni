import Foundation
import WidgetKit

actor WidgetSnapshotWriter {
    static let shared = WidgetSnapshotWriter()

    private var lastSystemWrite = Date.distantPast
    private var lastTimelineReload = Date.distantPast

    func persistSystem(_ snapshot: WidgetSystemSnapshot) {
        guard snapshot.date.timeIntervalSince(lastSystemWrite) >= 15 else { return }
        lastSystemWrite = snapshot.date
        try? MoniWidgetStorage.saveSystem(snapshot)

        if snapshot.date.timeIntervalSince(lastTimelineReload) >= 5 * 60 {
            lastTimelineReload = snapshot.date
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    func persistAI(_ snapshot: WidgetAISnapshot) {
        try? MoniWidgetStorage.saveAI(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }
}

extension WidgetSystemSnapshot {
    init(snapshot: SystemSnapshot, histories: Histories) {
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
                transmitRateBitsPerSecond: snapshot.network.wifi?.transmitRateBitsPerSecond
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
            docker: Docker(isInstalled: snapshot.docker.isInstalled, isRunning: snapshot.docker.isRunning, installation: snapshot.docker.installation),
            histories: histories
        )
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
                    quotas: provider.quotaWindows.map { quota in
                        .init(label: quota.label, remainingPercent: quota.remainingPercent, resetsAt: quota.resetsAt)
                    }
                )
            },
            daily: summary.daily.map { .init(date: $0.date, tokens: $0.tokens, costUSD: $0.costUSD) }
        )
    }
}
