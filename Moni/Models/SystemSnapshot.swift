import Foundation

struct CPUUsage: Sendable {
    var total: Double = 0
    var user: Double = 0
    var system: Double = 0
    var idle: Double = 100
    var perCore: [Double] = []
}

struct MemoryUsage: Sendable {
    var totalBytes: UInt64 = 0
    var usedBytes: UInt64 = 0
    var freeBytes: UInt64 = 0
    var cachedBytes: UInt64 = 0
    var wiredBytes: UInt64 = 0
    var compressedBytes: UInt64 = 0

    var usedPercent: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(usedBytes) / Double(totalBytes) * 100
    }
}

struct NetworkInterfaceUsage: Identifiable, Sendable {
    let name: String
    let receivedBytes: UInt64
    let sentBytes: UInt64
    let isActive: Bool

    var id: String { name }
}

struct NetworkUsage: Sendable {
    var downloadBytesPerSecond: Double = 0
    var uploadBytesPerSecond: Double = 0
    var totalReceivedBytes: UInt64 = 0
    var totalSentBytes: UInt64 = 0
    var interfaces: [NetworkInterfaceUsage] = []
}

struct VolumeUsage: Identifiable, Sendable {
    let name: String
    let mountPath: String
    let totalBytes: Int64
    let availableBytes: Int64

    var id: String { mountPath }
    var usedBytes: Int64 { max(0, totalBytes - availableBytes) }
    var usedPercent: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(usedBytes) / Double(totalBytes) * 100
    }
}

struct ProcessUsage: Identifiable, Sendable {
    let pid: Int32
    let name: String
    let path: String
    let cpuPercent: Double
    let memoryBytes: UInt64

    var id: Int32 { pid }
}

struct PowerUsage: Sendable {
    var batteryPercent: Double?
    var isCharging = false
    var timeRemainingMinutes: Int?
}

struct GPUDeviceInfo: Identifiable, Sendable {
    let registryID: UInt64
    let name: String
    let isLowPower: Bool
    let isRemovable: Bool
    let hasUnifiedMemory: Bool
    let recommendedMaxWorkingSetSize: UInt64

    var id: UInt64 { registryID }
}

struct DockerStatus: Sendable {
    var isInstalled = false
    var isRunning = false
    var installation: String?
    var socketPath: String?
}

struct HostDetails: Sendable {
    var name = ProcessInfo.processInfo.hostName
    var model = "Mac"
    var chip = "Apple Silicon"
    var operatingSystem = ProcessInfo.processInfo.operatingSystemVersionString
    var kernel = "Darwin"
    var uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    var loadAverages: [Double] = [0, 0, 0]
    var processorCount = ProcessInfo.processInfo.processorCount
}

struct SystemSnapshot: Sendable {
    var date = Date()
    var host = HostDetails()
    var cpu = CPUUsage()
    var memory = MemoryUsage()
    var network = NetworkUsage()
    var volumes: [VolumeUsage] = []
    var processes: [ProcessUsage] = []
    var power = PowerUsage()
    var gpuDevices: [GPUDeviceInfo] = []
    var docker = DockerStatus()
}
