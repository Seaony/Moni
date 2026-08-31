import Foundation

enum SystemHealthLevel: Sendable {
    case excellent
    case good
    case fair
    case needsAttention
}

enum SystemHealthDiagnosis: Sendable {
    case allClear
    case smartWarning
    case highCPU(processName: String?)
    case memoryPressure(processName: String?)
    case lowDiskSpace(availableBytes: Int64)
    case batteryHealth
    case highTemperature
    case busyDisk
    case restartRecommended
}

struct SystemHealth: Sendable {
    let score: Int
    let level: SystemHealthLevel
    let diagnosis: SystemHealthDiagnosis
}

extension SystemSnapshot {
    var systemHealth: SystemHealth {
        var score = 100.0

        score -= scaledPenalty(
            value: cpu.total,
            threshold: 50,
            maximumValue: 100,
            maximumPenalty: 30
        )
        score -= scaledPenalty(
            value: memory.usedPercent,
            threshold: 70,
            maximumValue: 100,
            maximumPenalty: 25
        )

        switch memory.pressure {
        case .warning:
            score -= 5
        case .critical:
            score -= 15
        case .normal, .unavailable:
            break
        }

        if let rootVolume = volumes.first(where: { $0.mountPath == "/" }) {
            score -= scaledPenalty(
                value: rootVolume.usedPercent,
                threshold: 80,
                maximumValue: 100,
                maximumPenalty: 20
            )
        }

        let smartWarning = driveHealth.smartStatus?.localizedCaseInsensitiveContains("warning") == true
        if smartWarning {
            score = min(score, 44)
        }

        if let temperature = power.cpuTemperatureCelsius {
            score -= scaledPenalty(
                value: temperature,
                threshold: 65,
                maximumValue: 85,
                maximumPenalty: 15
            )
        }

        let diskBytesPerSecond = diskActivity.readBytesPerSecond + diskActivity.writeBytesPerSecond
        score -= scaledPenalty(
            value: diskBytesPerSecond,
            threshold: 50_000_000,
            maximumValue: 150_000_000,
            maximumPenalty: 10
        )

        if let batteryHealth = power.batteryHealthPercent {
            if batteryHealth < 60 {
                score -= 5
            } else if batteryHealth < 80 {
                score -= 2
            }
        }
        if let cycles = power.cycleCount {
            if cycles > 900 {
                score -= 5
            } else if cycles > 800 {
                score -= 2
            }
        }

        if host.uptime > 14 * 86_400 {
            score -= 3
        } else if host.uptime > 7 * 86_400 {
            score -= 1
        }

        let clampedScore = Int(min(100, max(0, score)).rounded(.down))
        return SystemHealth(
            score: clampedScore,
            level: healthLevel(for: clampedScore),
            diagnosis: primaryDiagnosis(smartWarning: smartWarning)
        )
    }

    private func scaledPenalty(
        value: Double,
        threshold: Double,
        maximumValue: Double,
        maximumPenalty: Double
    ) -> Double {
        guard value > threshold else { return 0 }
        let progress = min(1, (value - threshold) / (maximumValue - threshold))
        return maximumPenalty * progress
    }

    private func healthLevel(for score: Int) -> SystemHealthLevel {
        switch score {
        case 85...: .excellent
        case 65...: .good
        case 45...: .fair
        default: .needsAttention
        }
    }

    private func primaryDiagnosis(smartWarning: Bool) -> SystemHealthDiagnosis {
        if smartWarning {
            return .smartWarning
        }
        if cpu.total > 85 {
            return .highCPU(processName: processes.max(by: { $0.cpuPercent < $1.cpuPercent })?.name)
        }
        if memory.pressure == .warning || memory.pressure == .critical || memory.usedPercent > 88 {
            return .memoryPressure(processName: processes.max(by: { $0.memoryBytes < $1.memoryBytes })?.name)
        }
        if let rootVolume = volumes.first(where: { $0.mountPath == "/" }), rootVolume.usedPercent > 93 {
            return .lowDiskSpace(availableBytes: rootVolume.availableBytes)
        }
        if (power.batteryHealthPercent.map { $0 < 80 } ?? false)
            || (power.cycleCount.map { $0 > 800 } ?? false) {
            return .batteryHealth
        }
        if (power.cpuTemperatureCelsius ?? 0) > 65 {
            return .highTemperature
        }
        if diskActivity.readBytesPerSecond + diskActivity.writeBytesPerSecond > 150_000_000 {
            return .busyDisk
        }
        if host.uptime > 14 * 86_400 {
            return .restartRecommended
        }
        return .allClear
    }
}
