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
    let kind: String
    let address: String?
    let receivedBytes: UInt64
    let sentBytes: UInt64
    let isActive: Bool
    let linkSpeedBitsPerSecond: UInt64

    var id: String { name }
}

struct WiFiUsage: Sendable {
    let interfaceName: String
    let physicalMode: String
    let networkName: String?
    let signalStrengthDBm: Int?
    let channelDescription: String?
    let transmitRateBitsPerSecond: UInt64
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
    var primaryInterfaceName: String?
    var gateway: String?
    var wifi: WiFiUsage?
    var interfaces: [NetworkInterfaceUsage] = []
    var connections: [NetworkConnectionUsage] = []

    nonisolated init(
        downloadBytesPerSecond: Double = 0,
        uploadBytesPerSecond: Double = 0,
        totalReceivedBytes: UInt64 = 0,
        totalSentBytes: UInt64 = 0,
        primaryInterfaceName: String? = nil,
        gateway: String? = nil,
        wifi: WiFiUsage? = nil,
        interfaces: [NetworkInterfaceUsage] = [],
        connections: [NetworkConnectionUsage] = []
    ) {
        self.downloadBytesPerSecond = downloadBytesPerSecond
        self.uploadBytesPerSecond = uploadBytesPerSecond
        self.totalReceivedBytes = totalReceivedBytes
        self.totalSentBytes = totalSentBytes
        self.primaryInterfaceName = primaryInterfaceName
        self.gateway = gateway
        self.wifi = wifi
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

struct StorageFolderUsage: Codable, Identifiable, Sendable {
    let path: String
    let sizeBytes: UInt64

    var id: String { path }
}

struct DiskActivity: Sendable {
    var readBytesPerSecond: Double = 0
    var writeBytesPerSecond: Double = 0
    var readOperationsPerSecond: Double = 0
    var writeOperationsPerSecond: Double = 0

    nonisolated init(
        readBytesPerSecond: Double = 0,
        writeBytesPerSecond: Double = 0,
        readOperationsPerSecond: Double = 0,
        writeOperationsPerSecond: Double = 0
    ) {
        self.readBytesPerSecond = readBytesPerSecond
        self.writeBytesPerSecond = writeBytesPerSecond
        self.readOperationsPerSecond = readOperationsPerSecond
        self.writeOperationsPerSecond = writeOperationsPerSecond
    }
}

struct DriveHealth: Sendable {
    var model: String?
    var smartStatus: String?
    var trimEnabled: Bool?
    var temperatureCelsius: Double?
    var totalWrittenBytes: UInt64?

    nonisolated init(
        model: String? = nil,
        smartStatus: String? = nil,
        trimEnabled: Bool? = nil,
        temperatureCelsius: Double? = nil,
        totalWrittenBytes: UInt64? = nil
    ) {
        self.model = model
        self.smartStatus = smartStatus
        self.trimEnabled = trimEnabled
        self.temperatureCelsius = temperatureCelsius
        self.totalWrittenBytes = totalWrittenBytes
    }
}

struct ProcessUsage: Identifiable, Sendable {
    let pid: Int32
    let name: String
    let path: String
    let cpuPercent: Double
    let memoryBytes: UInt64
    let threadCount: Int

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
    var isExternalPowerConnected = false
    var timeRemainingMinutes: Int?
    var batteryTemperatureCelsius: Double?
    var cycleCount: Int?
    var batteryHealth: String?
    var batteryHealthPercent: Double?
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
        isExternalPowerConnected: Bool = false,
        timeRemainingMinutes: Int? = nil,
        batteryTemperatureCelsius: Double? = nil,
        cycleCount: Int? = nil,
        batteryHealth: String? = nil,
        batteryHealthPercent: Double? = nil,
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
        self.isExternalPowerConnected = isExternalPowerConnected
        self.timeRemainingMinutes = timeRemainingMinutes
        self.batteryTemperatureCelsius = batteryTemperatureCelsius
        self.cycleCount = cycleCount
        self.batteryHealth = batteryHealth
        self.batteryHealthPercent = batteryHealthPercent
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
    let vendor: String
    let coreCount: Int?
    let metalSupport: String?
    let hasUnifiedMemory: Bool
    let unifiedMemoryBytes: UInt64?
    let mainDisplayResolution: String?
    let mainDisplayDiagonalInches: Double?
    let mainDisplayRefreshRateHertz: Double?

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

struct DockerContainerUsage: Identifiable, Sendable {
    let name: String
    let state: String
    let status: String

    var id: String { name }
}

struct DockerStatus: Sendable {
    var isInstalled = false
    var isRunning = false
    var installation: String?
    var socketPath: String?
    var containers: [DockerContainerUsage] = []

    nonisolated init(
        isInstalled: Bool = false,
        isRunning: Bool = false,
        installation: String? = nil,
        socketPath: String? = nil,
        containers: [DockerContainerUsage] = []
    ) {
        self.isInstalled = isInstalled
        self.isRunning = isRunning
        self.installation = installation
        self.socketPath = socketPath
        self.containers = containers
    }

    var runningContainerCount: Int {
        containers.filter { $0.state == "running" }.count
    }

    var statusTitle: String {
        if isRunning { return MoniLocalization.string("Running") }
        if isInstalled { return MoniLocalization.string("Not Running") }
        return MoniLocalization.string("Not Detected")
    }

    var statusReason: String {
        if isRunning, let socketPath {
            return MoniLocalization.format("Local engine connected at %@.", socketPath)
        }
        if isInstalled, let socketPath {
            return MoniLocalization.format(
                "%@ was detected, but the local engine socket at %@ is not accepting connections.",
                installation ?? "Docker",
                socketPath
            )
        }
        if isInstalled {
            return MoniLocalization.format(
                "%@ is installed, but no supported local engine socket was found.",
                installation ?? "Docker"
            )
        }
        return MoniLocalization.string("Docker Desktop, OrbStack, and Docker CLI were not found in the supported locations.")
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
    var driveHealth = DriveHealth()
    var volumes: [VolumeUsage] = []
    var processes: [ProcessUsage] = []
    var power = PowerUsage()
    var gpuDevices: [GPUDeviceInfo] = []
    var gpu = GPUUsage()
    var docker = DockerStatus()
}
