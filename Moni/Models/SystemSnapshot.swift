import Foundation

struct CPUUsage: Sendable {
    var total: Double = 0
    var user: Double = 0
    var system: Double = 0
    var idle: Double = 100
    var perCore: [Double] = []

    nonisolated init(
        total: Double = 0,
        user: Double = 0,
        system: Double = 0,
        idle: Double = 100,
        perCore: [Double] = []
    ) {
        self.total = total
        self.user = user
        self.system = system
        self.idle = idle
        self.perCore = perCore
    }
}

struct MemoryUsage: Sendable {
    var totalBytes: UInt64 = 0
    var usedBytes: UInt64 = 0
    var freeBytes: UInt64 = 0
    var cachedBytes: UInt64 = 0
    var wiredBytes: UInt64 = 0
    var compressedBytes: UInt64 = 0

    nonisolated init(
        totalBytes: UInt64 = 0,
        usedBytes: UInt64 = 0,
        freeBytes: UInt64 = 0,
        cachedBytes: UInt64 = 0,
        wiredBytes: UInt64 = 0,
        compressedBytes: UInt64 = 0
    ) {
        self.totalBytes = totalBytes
        self.usedBytes = usedBytes
        self.freeBytes = freeBytes
        self.cachedBytes = cachedBytes
        self.wiredBytes = wiredBytes
        self.compressedBytes = compressedBytes
    }

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

    nonisolated init(
        downloadBytesPerSecond: Double = 0,
        uploadBytesPerSecond: Double = 0,
        totalReceivedBytes: UInt64 = 0,
        totalSentBytes: UInt64 = 0,
        interfaces: [NetworkInterfaceUsage] = []
    ) {
        self.downloadBytesPerSecond = downloadBytesPerSecond
        self.uploadBytesPerSecond = uploadBytesPerSecond
        self.totalReceivedBytes = totalReceivedBytes
        self.totalSentBytes = totalSentBytes
        self.interfaces = interfaces
    }
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

    nonisolated init(
        batteryPercent: Double? = nil,
        isCharging: Bool = false,
        timeRemainingMinutes: Int? = nil
    ) {
        self.batteryPercent = batteryPercent
        self.isCharging = isCharging
        self.timeRemainingMinutes = timeRemainingMinutes
    }
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

    nonisolated init(
        isInstalled: Bool = false,
        isRunning: Bool = false,
        installation: String? = nil,
        socketPath: String? = nil
    ) {
        self.isInstalled = isInstalled
        self.isRunning = isRunning
        self.installation = installation
        self.socketPath = socketPath
    }

    var statusTitle: String {
        if isRunning { return "Running" }
        if isInstalled { return "Not Running" }
        return "Not Detected"
    }

    var statusReason: String {
        if isRunning, let socketPath {
            return "Local engine socket detected at \(socketPath)."
        }
        if isInstalled {
            return "\(installation ?? "Docker") is installed, but no supported local engine socket was found."
        }
        return "Docker Desktop, OrbStack, and Docker CLI were not found in the supported locations."
    }
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

    nonisolated init(
        name: String = ProcessInfo.processInfo.hostName,
        model: String = "Mac",
        chip: String = "Apple Silicon",
        operatingSystem: String = ProcessInfo.processInfo.operatingSystemVersionString,
        kernel: String = "Darwin",
        uptime: TimeInterval = ProcessInfo.processInfo.systemUptime,
        loadAverages: [Double] = [0, 0, 0],
        processorCount: Int = ProcessInfo.processInfo.processorCount
    ) {
        self.name = name
        self.model = model
        self.chip = chip
        self.operatingSystem = operatingSystem
        self.kernel = kernel
        self.uptime = uptime
        self.loadAverages = loadAverages
        self.processorCount = processorCount
    }
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
