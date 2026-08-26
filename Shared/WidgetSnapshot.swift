import Foundation

nonisolated struct WidgetSystemSnapshot: Codable, Sendable {
    struct CPU: Codable, Sendable {
        let total: Double
        let user: Double
        let system: Double
        let perCore: [Double]
    }

    struct Memory: Codable, Sendable {
        let totalBytes: UInt64
        let usedBytes: UInt64
        let freeBytes: UInt64
        let wiredBytes: UInt64
        let compressedBytes: UInt64
        let swapUsedBytes: UInt64
        let pageIns: UInt64

        var usedPercent: Double {
            guard totalBytes > 0 else { return 0 }
            return Double(usedBytes) / Double(totalBytes) * 100
        }
    }

    struct Volume: Codable, Sendable {
        let name: String
        let totalBytes: Int64
        let availableBytes: Int64

        var usedPercent: Double {
            guard totalBytes > 0 else { return 0 }
            return Double(max(0, totalBytes - availableBytes)) / Double(totalBytes) * 100
        }
    }

    struct Network: Codable, Sendable {
        let downloadBytesPerSecond: Double
        let uploadBytesPerSecond: Double
        let interfaceName: String?
        let networkName: String?
        let physicalMode: String?
        let signalStrengthDBm: Int?
        let channel: String?
        let transmitRateBitsPerSecond: UInt64?
    }

    struct Process: Codable, Sendable {
        let name: String
        let cpuPercent: Double
        let memoryBytes: UInt64
        let threadCount: Int
    }

    struct Sensor: Codable, Sendable {
        let name: String
        let celsius: Double
    }

    struct Power: Codable, Sendable {
        let batteryPercent: Double?
        let isCharging: Bool
        let batteryTemperatureCelsius: Double?
        let cycleCount: Int?
        let batteryHealth: String?
        let systemPowerWatts: Double?
        let cpuTemperatureCelsius: Double?
        let gpuTemperatureCelsius: Double?
        let fanRPM: Double?
    }

    struct GPU: Codable, Sendable {
        let name: String?
        let coreCount: Int?
        let utilizationPercent: Double?
        let rendererPercent: Double?
        let tilerPercent: Double?
        let allocatedMemoryBytes: UInt64?
        let powerWatts: Double?
    }

    struct Docker: Codable, Sendable {
        let isInstalled: Bool
        let isRunning: Bool
        let installation: String?
        let socketPath: String?
    }

    struct Histories: Codable, Sendable {
        let cpu: [Double]
        let memory: [Double]
        let download: [Double]
        let upload: [Double]
        let gpu: [Double]
        let diskRead: [Double]
        let diskWrite: [Double]
        let battery: [Double]
    }

    let date: Date
    let hostName: String
    let uptime: TimeInterval
    let loadAverages: [Double]
    let cpu: CPU
    let memory: Memory
    let volume: Volume?
    let diskReadBytesPerSecond: Double
    let diskWriteBytesPerSecond: Double
    let diskReadOperationsPerSecond: Double
    let diskWriteOperationsPerSecond: Double
    let driveModel: String?
    let driveSmartStatus: String?
    let driveTemperatureCelsius: Double?
    let network: Network
    let processCount: Int
    let threadCount: Int
    let processes: [Process]
    let sensors: [Sensor]
    let power: Power
    let gpu: GPU
    let docker: Docker
    let histories: Histories

    static let placeholder = WidgetSystemSnapshot(
        date: .now,
        hostName: "Mac",
        uptime: 2 * 86_400 + 6 * 3_600,
        loadAverages: [5.98, 5.56, 4.66],
        cpu: CPU(total: 68, user: 52, system: 16, perCore: [24, 73, 58, 81, 65, 77, 45, 69, 31, 54]),
        memory: Memory(totalBytes: 16_000_000_000, usedBytes: 12_300_000_000, freeBytes: 3_700_000_000, wiredBytes: 2_100_000_000, compressedBytes: 1_400_000_000, swapUsedBytes: 512_000_000, pageIns: 18_429),
        volume: Volume(name: "Macintosh HD", totalBytes: 926_400_000_000, availableBytes: 74_900_000_000),
        diskReadBytesPerSecond: 629_000,
        diskWriteBytesPerSecond: 0,
        diskReadOperationsPerSecond: 84,
        diskWriteOperationsPerSecond: 12,
        driveModel: "APPLE SSD",
        driveSmartStatus: "Verified",
        driveTemperatureCelsius: 36,
        network: Network(downloadBytesPerSecond: 45_000, uploadBytesPerSecond: 8_000, interfaceName: "en0", networkName: "Studio 5G", physicalMode: "Wi-Fi 6", signalStrengthDBm: -46, channel: "149", transmitRateBitsPerSecond: 1_200_000_000),
        processCount: 1_084,
        threadCount: 5_912,
        processes: [Process(name: "WindowServer", cpuPercent: 95, memoryBytes: 1_400_000_000, threadCount: 24), Process(name: "clangd", cpuPercent: 73, memoryBytes: 1_200_000_000, threadCount: 18)],
        sensors: [Sensor(name: "CPU die", celsius: 44), Sensor(name: "GPU die", celsius: 42), Sensor(name: "SSD", celsius: 36), Sensor(name: "Battery", celsius: 32)],
        power: Power(batteryPercent: 82, isCharging: true, batteryTemperatureCelsius: 32, cycleCount: 312, batteryHealth: "Normal", systemPowerWatts: 18.6, cpuTemperatureCelsius: 44, gpuTemperatureCelsius: 42, fanRPM: 2_359),
        gpu: GPU(name: "Apple GPU", coreCount: 16, utilizationPercent: 19, rendererPercent: 17, tilerPercent: 11, allocatedMemoryBytes: 1_700_000_000, powerWatts: 5.2),
        docker: Docker(isInstalled: true, isRunning: true, installation: "Docker", socketPath: "/var/run/docker.sock"),
        histories: Histories(cpu: [28, 35, 52, 46, 68], memory: [73, 74, 75, 76, 77], download: [22, 55, 61, 42, 45], upload: [9, 14, 12, 7, 8], gpu: [8, 12, 16, 14, 19], diskRead: [12, 34, 28, 51, 42], diskWrite: [8, 11, 26, 18, 21], battery: [96, 93, 90, 86, 82])
    )
}

nonisolated struct WidgetAIProvider: Codable, Sendable {
    struct Quota: Codable, Sendable {
        let label: String
        let remainingPercent: Double
        let resetsAt: Date?
    }

    let name: String
    let plan: String?
    let totalTokens: UInt64
    let estimatedCostUSD: Double?
    let cacheHitPercent: Double?
    let quotas: [Quota]
}

nonisolated struct WidgetAISnapshot: Codable, Sendable {
    struct Day: Codable, Sendable {
        let date: Date
        let tokens: UInt64
        let costUSD: Double
    }

    let date: Date
    let totalTokens: UInt64
    let estimatedCostUSD: Double?
    let providers: [WidgetAIProvider]
    let daily: [Day]

    static let placeholder: WidgetAISnapshot = {
        let now = Date.now
        let providers = [
            WidgetAIProvider(
                name: "Claude",
                plan: "Max",
                totalTokens: 820_000_000,
                estimatedCostUSD: 1_530,
                cacheHitPercent: 98,
                quotas: [.init(label: "Weekly", remainingPercent: 84, resetsAt: now.addingTimeInterval(2 * 86_400))]
            ),
            WidgetAIProvider(
                name: "Codex",
                plan: "Plus",
                totalTokens: 82_900_000,
                estimatedCostUSD: 321,
                cacheHitPercent: 96,
                quotas: [.init(label: "Weekly", remainingPercent: 97, resetsAt: now.addingTimeInterval(5 * 86_400))]
            )
        ]
        let daily: [Day] = (0..<14).map { index in
            let amount = index * index + 4
            return Day(
                date: now.addingTimeInterval(Double(index - 13) * 86_400),
                tokens: UInt64(amount) * 1_000_000,
                costUSD: Double(amount) * 0.42
            )
        }
        return WidgetAISnapshot(
            date: now,
            totalTokens: 2_640_000_000,
            estimatedCostUSD: 2_489,
            providers: providers,
            daily: daily
        )
    }()
}

nonisolated enum MoniWidgetStorage {
    static let appGroupIdentifier = "group.com.seaony.Moni"
    private static let systemFileName = "widget-system.json"
    private static let aiFileName = "widget-ai.json"

    static func loadSystem() -> WidgetSystemSnapshot? {
        load(WidgetSystemSnapshot.self, fileName: systemFileName)
    }

    static func loadAI() -> WidgetAISnapshot? {
        load(WidgetAISnapshot.self, fileName: aiFileName)
    }

    static func saveSystem(_ snapshot: WidgetSystemSnapshot) throws {
        try save(snapshot, fileName: systemFileName)
    }

    static func saveAI(_ snapshot: WidgetAISnapshot) throws {
        try save(snapshot, fileName: aiFileName)
    }

    private static func load<Value: Decodable>(_ type: Value.Type, fileName: String) -> Value? {
        guard let url = fileURL(fileName), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func save<Value: Encodable>(_ value: Value, fileName: String) throws {
        guard let url = fileURL(fileName) else { return }
        let data = try JSONEncoder().encode(value)
        try data.write(to: url, options: .atomic)
    }

    private static func fileURL(_ fileName: String) -> URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        )?.appending(path: fileName)
    }
}
