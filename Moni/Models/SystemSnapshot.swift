import Foundation

struct CPUUsage: Sendable {
    var total: Double = 0
    var user: Double = 0
    var system: Double = 0
    var nice: Double = 0
    var idle: Double = 100
    var perCore: [Double] = []

    nonisolated init(
        total: Double = 0,
        user: Double = 0,
        system: Double = 0,
        nice: Double = 0,
        idle: Double = 100,
        perCore: [Double] = []
    ) {
        self.total = total
        self.user = user
        self.system = system
        self.nice = nice
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
    var swapUsedBytes: UInt64 = 0
    var pageIns: UInt64 = 0
    var pageOuts: UInt64 = 0
    var faults: UInt64 = 0

    nonisolated init(
        totalBytes: UInt64 = 0,
        usedBytes: UInt64 = 0,
        freeBytes: UInt64 = 0,
        cachedBytes: UInt64 = 0,
        wiredBytes: UInt64 = 0,
        compressedBytes: UInt64 = 0,
        swapUsedBytes: UInt64 = 0,
        pageIns: UInt64 = 0,
        pageOuts: UInt64 = 0,
        faults: UInt64 = 0
    ) {
        self.totalBytes = totalBytes
        self.usedBytes = usedBytes
        self.freeBytes = freeBytes
        self.cachedBytes = cachedBytes
        self.wiredBytes = wiredBytes
        self.compressedBytes = compressedBytes
        self.swapUsedBytes = swapUsedBytes
        self.pageIns = pageIns
        self.pageOuts = pageOuts
        self.faults = faults
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
    let linkSpeedBitsPerSecond: UInt64

    var id: String { name }
}

struct NetworkConnectionUsage: Identifiable, Sendable {
    let processName: String
    let pid: Int32
    let localEndpoint: String
    let remoteEndpoint: String
    let transport: String
    let receivedBytes: UInt64
    let sentBytes: UInt64

    var id: String { "\(pid)-\(transport)-\(localEndpoint)-\(remoteEndpoint)" }
}

struct NetworkUsage: Sendable {
    var downloadBytesPerSecond: Double = 0
    var uploadBytesPerSecond: Double = 0
    var totalReceivedBytes: UInt64 = 0
    var totalSentBytes: UInt64 = 0
    var interfaces: [NetworkInterfaceUsage] = []
    var connections: [NetworkConnectionUsage] = []

    nonisolated init(
        downloadBytesPerSecond: Double = 0,
        uploadBytesPerSecond: Double = 0,
        totalReceivedBytes: UInt64 = 0,
        totalSentBytes: UInt64 = 0,
        interfaces: [NetworkInterfaceUsage] = [],
        connections: [NetworkConnectionUsage] = []
    ) {
        self.downloadBytesPerSecond = downloadBytesPerSecond
        self.uploadBytesPerSecond = uploadBytesPerSecond
        self.totalReceivedBytes = totalReceivedBytes
        self.totalSentBytes = totalSentBytes
        self.interfaces = interfaces
        self.connections = connections
    }
}

struct VolumeUsage: Identifiable, Sendable {
    let name: String
    let mountPath: String
    let format: String?
    let totalBytes: Int64
    let availableBytes: Int64

    var id: String { mountPath }
    var usedBytes: Int64 { max(0, totalBytes - availableBytes) }
    var usedPercent: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(usedBytes) / Double(totalBytes) * 100
    }
}

struct DiskActivity: Sendable {
    var readBytesPerSecond: Double = 0
    var writeBytesPerSecond: Double = 0

    nonisolated init(readBytesPerSecond: Double = 0, writeBytesPerSecond: Double = 0) {
        self.readBytesPerSecond = readBytesPerSecond
        self.writeBytesPerSecond = writeBytesPerSecond
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

struct TemperatureSensor: Identifiable, Sendable {
    let name: String
    let valueCelsius: Double

    var id: String { name }
}

struct FanUsage: Identifiable, Sendable {
    let index: Int
    let name: String
    let revolutionsPerMinute: Double

    var id: Int { index }
}

struct PowerUsage: Sendable {
    var batteryPercent: Double?
    var isCharging = false
    var timeRemainingMinutes: Int?
    var batteryTemperatureCelsius: Double?
    var cycleCount: Int?
    var voltageVolts: Double?
    var currentAmps: Double?
    var systemPowerWatts: Double?
    var cpuTemperatureCelsius: Double?
    var gpuTemperatureCelsius: Double?
    var temperatureSensors: [TemperatureSensor]
    var fans: [FanUsage]
    var cpuPowerWatts: Double?
    var gpuPowerWatts: Double?
    var neuralEnginePowerWatts: Double?
    var memoryPowerWatts: Double?

    nonisolated init(
        batteryPercent: Double? = nil,
        isCharging: Bool = false,
        timeRemainingMinutes: Int? = nil,
        batteryTemperatureCelsius: Double? = nil,
        cycleCount: Int? = nil,
        voltageVolts: Double? = nil,
        currentAmps: Double? = nil,
        systemPowerWatts: Double? = nil,
        cpuTemperatureCelsius: Double? = nil,
        gpuTemperatureCelsius: Double? = nil,
        temperatureSensors: [TemperatureSensor] = [],
        fans: [FanUsage] = [],
        cpuPowerWatts: Double? = nil,
        gpuPowerWatts: Double? = nil,
        neuralEnginePowerWatts: Double? = nil,
        memoryPowerWatts: Double? = nil
    ) {
        self.batteryPercent = batteryPercent
        self.isCharging = isCharging
        self.timeRemainingMinutes = timeRemainingMinutes
        self.batteryTemperatureCelsius = batteryTemperatureCelsius
        self.cycleCount = cycleCount
        self.voltageVolts = voltageVolts
        self.currentAmps = currentAmps
        self.systemPowerWatts = systemPowerWatts
        self.cpuTemperatureCelsius = cpuTemperatureCelsius
        self.gpuTemperatureCelsius = gpuTemperatureCelsius
        self.temperatureSensors = temperatureSensors
        self.fans = fans
        self.cpuPowerWatts = cpuPowerWatts
        self.gpuPowerWatts = gpuPowerWatts
        self.neuralEnginePowerWatts = neuralEnginePowerWatts
        self.memoryPowerWatts = memoryPowerWatts
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

struct GPUClientUsage: Identifiable, Sendable {
    let pid: Int32
    let name: String
    let memoryBytes: UInt64
    let utilizationPercent: Double

    var id: Int32 { pid }
}

struct GPUUsage: Sendable {
    var utilizationPercent: Double?
    var rendererPercent: Double?
    var tilerPercent: Double?
    var allocatedMemoryBytes: UInt64?
    var clients: [GPUClientUsage]

    nonisolated init(
        utilizationPercent: Double? = nil,
        rendererPercent: Double? = nil,
        tilerPercent: Double? = nil,
        allocatedMemoryBytes: UInt64? = nil,
        clients: [GPUClientUsage] = []
    ) {
        self.utilizationPercent = utilizationPercent
        self.rendererPercent = rendererPercent
        self.tilerPercent = tilerPercent
        self.allocatedMemoryBytes = allocatedMemoryBytes
        self.clients = clients
    }
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
    var diskActivity = DiskActivity()
    var volumes: [VolumeUsage] = []
    var processes: [ProcessUsage] = []
    var power = PowerUsage()
    var gpuDevices: [GPUDeviceInfo] = []
    var gpu = GPUUsage()
    var docker = DockerStatus()
}
