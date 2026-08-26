import Darwin
import Foundation
import IOKit
import IOKit.ps
import Metal

actor SystemSampler {
    private struct HostIdentity {
        let name: String
        let model: String
        let chip: String
        let operatingSystem: String
        let kernel: String
        let processorCount: Int
    }

    private struct CPUTicks {
        let user: UInt64
        let system: UInt64
        let idle: UInt64
        let nice: UInt64

        var total: UInt64 { user + system + idle + nice }
    }

    private var previousCPUTicks: [CPUTicks] = []
    private var previousNetworkBytes: (received: UInt64, sent: UInt64, date: Date)?
    private var previousDiskBytes: (read: UInt64, written: UInt64, date: Date)?
    private var previousProcessTimes: [Int32: UInt64] = [:]
    private var previousProcessDate: Date?
    private var previousGPUClientTimes: [Int32: UInt64] = [:]
    private var previousGPUClientDate: Date?
    private var processMetadata: [Int32: (name: String, path: String)] = [:]
    private var previousEnergyCounters: (values: [String: Double], date: Date)?
    private let smcReader = SMCSensorReader()

    private var hostIdentity: HostIdentity?
    private var gpuDevices: [GPUDeviceInfo] = []
    private var didLoadGPUDevices = false
    private var cachedVolumes: [VolumeUsage] = []
    private var cachedProcesses: [ProcessUsage] = []
    private var cachedPower = PowerUsage()
    private var cachedDocker = DockerStatus()
    private var lastProcessSample: Date?
    private var lastPeripheralSample: Date?

    private let processInterval: TimeInterval = 2
    private let peripheralInterval: TimeInterval = 5

    func sample(forceSlowMetrics: Bool = false) -> SystemSnapshot {
        let now = Date()
        if hostIdentity == nil {
            hostIdentity = Self.loadHostIdentity()
        }
        if !didLoadGPUDevices {
            gpuDevices = Self.loadGPUDevices()
            didLoadGPUDevices = true
        }
        if forceSlowMetrics || shouldRefresh(lastProcessSample, at: now, interval: processInterval) {
            cachedProcesses = sampleProcesses(at: now)
            lastProcessSample = now
        }
        if forceSlowMetrics || shouldRefresh(lastPeripheralSample, at: now, interval: peripheralInterval) {
            cachedVolumes = sampleVolumes()
            cachedPower = samplePower()
            cachedDocker = sampleDockerStatus()
            lastPeripheralSample = now
        }

        return SystemSnapshot(
            date: now,
            host: sampleHost(),
            cpu: sampleCPU(),
            memory: sampleMemory(),
            network: sampleNetwork(at: now),
            diskActivity: sampleDiskActivity(at: now),
            volumes: cachedVolumes,
            processes: cachedProcesses,
            power: cachedPower,
            gpuDevices: gpuDevices,
            gpu: sampleGPU(at: now),
            docker: cachedDocker
        )
    }

    private func shouldRefresh(_ previous: Date?, at date: Date, interval: TimeInterval) -> Bool {
        guard let previous else { return true }
        return date.timeIntervalSince(previous) >= interval
    }

    private func sampleCPU() -> CPUUsage {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &cpuCount,
            &info,
            &infoCount
        )

        guard result == KERN_SUCCESS, let info else { return CPUUsage() }
        defer {
            let size = vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), size)
        }

        let stateCount = Int(CPU_STATE_MAX)
        let current = (0 ..< Int(cpuCount)).map { index in
            let offset = index * stateCount
            return CPUTicks(
                user: UInt64(UInt32(bitPattern: info[offset + Int(CPU_STATE_USER)])),
                system: UInt64(UInt32(bitPattern: info[offset + Int(CPU_STATE_SYSTEM)])),
                idle: UInt64(UInt32(bitPattern: info[offset + Int(CPU_STATE_IDLE)])),
                nice: UInt64(UInt32(bitPattern: info[offset + Int(CPU_STATE_NICE)]))
            )
        }

        defer { previousCPUTicks = current }
        guard previousCPUTicks.count == current.count else {
            return CPUUsage(perCore: Array(repeating: 0, count: current.count))
        }

        let deltas = zip(current, previousCPUTicks).map { current, previous in
            CPUTicks(
                user: tickDelta(current.user, previous: previous.user),
                system: tickDelta(current.system, previous: previous.system),
                idle: tickDelta(current.idle, previous: previous.idle),
                nice: tickDelta(current.nice, previous: previous.nice)
            )
        }
        let aggregate = deltas.reduce(CPUTicks(user: 0, system: 0, idle: 0, nice: 0)) { partial, ticks in
            CPUTicks(
                user: partial.user + ticks.user,
                system: partial.system + ticks.system,
                idle: partial.idle + ticks.idle,
                nice: partial.nice + ticks.nice
            )
        }

        func percent(_ value: UInt64, total: UInt64) -> Double {
            guard total > 0 else { return 0 }
            return Double(value) / Double(total) * 100
        }

        let perCore = deltas.map { percent($0.user + $0.system + $0.nice, total: $0.total) }
        return CPUUsage(
            total: percent(aggregate.user + aggregate.system + aggregate.nice, total: aggregate.total),
            user: percent(aggregate.user, total: aggregate.total),
            system: percent(aggregate.system, total: aggregate.total),
            nice: percent(aggregate.nice, total: aggregate.total),
            idle: percent(aggregate.idle, total: aggregate.total),
            perCore: perCore
        )
    }

    private func tickDelta(_ current: UInt64, previous: UInt64) -> UInt64 {
        if current >= previous { return current - previous }
        return UInt64(UInt32.max) - previous + current + 1
    }

    private func sampleMemory() -> MemoryUsage {
        var statistics = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }

        guard result == KERN_SUCCESS else { return MemoryUsage() }

        let pageSize = UInt64(vm_kernel_page_size)
        let total = ProcessInfo.processInfo.physicalMemory
        let free = UInt64(statistics.free_count) * pageSize
        let cached = UInt64(statistics.inactive_count + statistics.speculative_count) * pageSize
        let wired = UInt64(statistics.wire_count) * pageSize
        let compressed = UInt64(statistics.compressor_page_count) * pageSize
        let used = total > free + cached ? total - free - cached : 0
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        let hasSwap = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0

        return MemoryUsage(
            totalBytes: total,
            usedBytes: used,
            freeBytes: free,
            cachedBytes: cached,
            wiredBytes: wired,
            compressedBytes: compressed,
            swapUsedBytes: hasSwap ? swap.xsu_used : 0,
            pageIns: UInt64(statistics.pageins),
            pageOuts: UInt64(statistics.pageouts),
            faults: UInt64(statistics.faults)
        )
    }

    private func sampleNetwork(at date: Date) -> NetworkUsage {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return NetworkUsage() }
        defer { freeifaddrs(pointer) }

        var interfaces: [NetworkInterfaceUsage] = []
        var received: UInt64 = 0
        var sent: UInt64 = 0
        var cursor: UnsafeMutablePointer<ifaddrs>? = first

        while let item = cursor?.pointee {
            defer { cursor = item.ifa_next }
            guard let address = item.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK), let data = item.ifa_data else {
                continue
            }

            let flags = Int32(item.ifa_flags)
            let isLoopback = flags & IFF_LOOPBACK != 0
            guard !isLoopback else { continue }

            let usage = data.assumingMemoryBound(to: if_data.self).pointee
            let name = String(cString: item.ifa_name)
            let isActive = flags & IFF_UP != 0 && flags & IFF_RUNNING != 0
            let interface = NetworkInterfaceUsage(
                name: name,
                receivedBytes: UInt64(usage.ifi_ibytes),
                sentBytes: UInt64(usage.ifi_obytes),
                isActive: isActive,
                linkSpeedBitsPerSecond: UInt64(usage.ifi_baudrate)
            )
            interfaces.append(interface)
            received += interface.receivedBytes
            sent += interface.sentBytes
        }

        let elapsed = previousNetworkBytes.map { date.timeIntervalSince($0.date) } ?? 0
        let previousReceived = previousNetworkBytes?.received ?? received
        let previousSent = previousNetworkBytes?.sent ?? sent
        let receivedDelta = received >= previousReceived ? received - previousReceived : 0
        let sentDelta = sent >= previousSent ? sent - previousSent : 0
        let download = elapsed > 0 ? Double(receivedDelta) / elapsed : 0
        let upload = elapsed > 0 ? Double(sentDelta) / elapsed : 0
        previousNetworkBytes = (received, sent, date)

        return NetworkUsage(
            downloadBytesPerSecond: download,
            uploadBytesPerSecond: upload,
            totalReceivedBytes: received,
            totalSentBytes: sent,
            interfaces: interfaces.sorted { $0.name < $1.name }
        )
    }

    private func sampleVolumes() -> [VolumeUsage] {
        let keys: Set<URLResourceKey> = [
            .volumeLocalizedNameKey,
            .volumeLocalizedFormatDescriptionKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(keys),
            options: [.skipHiddenVolumes]
        ) ?? [URL(fileURLWithPath: "/")]

        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys),
                  let total = values.volumeTotalCapacity,
                  let available = values.volumeAvailableCapacityForImportantUsage else {
                return nil
            }
            return VolumeUsage(
                name: values.volumeLocalizedName ?? url.lastPathComponent,
                mountPath: url.path,
                format: values.volumeLocalizedFormatDescription,
                totalBytes: Int64(total),
                availableBytes: available
            )
        }
        .sorted { lhs, rhs in
            if lhs.mountPath == "/" { return true }
            if rhs.mountPath == "/" { return false }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private func sampleDiskActivity(at date: Date) -> DiskActivity {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOBlockStorageDriver"),
            &iterator
        ) == KERN_SUCCESS else { return DiskActivity() }
        defer { IOObjectRelease(iterator) }

        var totalRead: UInt64 = 0
        var totalWritten: UInt64 = 0
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let statistics = IORegistryEntryCreateCFProperty(
                service,
                "Statistics" as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() as? [String: Any] {
                totalRead += (statistics["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
                totalWritten += (statistics["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }

        let elapsed = previousDiskBytes.map { date.timeIntervalSince($0.date) } ?? 0
        let priorRead = previousDiskBytes?.read ?? totalRead
        let priorWritten = previousDiskBytes?.written ?? totalWritten
        let readDelta = totalRead >= priorRead ? totalRead - priorRead : 0
        let writeDelta = totalWritten >= priorWritten ? totalWritten - priorWritten : 0
        previousDiskBytes = (totalRead, totalWritten, date)
        return DiskActivity(
            readBytesPerSecond: elapsed > 0 ? Double(readDelta) / elapsed : 0,
            writeBytesPerSecond: elapsed > 0 ? Double(writeDelta) / elapsed : 0
        )
    }

    private func sampleProcesses(at date: Date) -> [ProcessUsage] {
        let capacity = max(1, Int(proc_listallpids(nil, 0)))
        var pids = [pid_t](repeating: 0, count: capacity)
        let bytes = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard bytes > 0 else { return [] }

        let elapsed = previousProcessDate.map { date.timeIntervalSince($0) } ?? 0
        var currentTimes: [Int32: UInt64] = [:]
        var usages: [ProcessUsage] = []

        for pid in pids.prefix(Int(bytes)) where pid > 0 {
            var task = proc_taskinfo()
            let taskSize = Int32(MemoryLayout<proc_taskinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, taskSize) == taskSize else { continue }

            let totalTime = task.pti_total_user + task.pti_total_system
            currentTimes[pid] = totalTime
            let priorTime = previousProcessTimes[pid]
            let previousTime = priorTime ?? totalTime
            let timeDelta = totalTime >= previousTime ? totalTime - previousTime : 0
            let cpu = elapsed > 0 ? Double(timeDelta) / (elapsed * 1_000_000_000) * 100 : 0
            let wasReused = priorTime.map { totalTime < $0 } ?? false
            let metadata: (name: String, path: String)
            if !wasReused, let cachedMetadata = processMetadata[pid] {
                metadata = cachedMetadata
            } else {
                metadata = loadProcessMetadata(pid: pid)
            }
            processMetadata[pid] = metadata

            usages.append(ProcessUsage(
                pid: pid,
                name: metadata.name,
                path: metadata.path,
                cpuPercent: max(0, cpu),
                memoryBytes: task.pti_resident_size
            ))
        }

        previousProcessTimes = currentTimes
        previousProcessDate = date
        processMetadata = processMetadata.filter { currentTimes[$0.key] != nil }
        return usages.sorted { lhs, rhs in
            if lhs.cpuPercent == rhs.cpuPercent { return lhs.memoryBytes > rhs.memoryBytes }
            return lhs.cpuPercent > rhs.cpuPercent
        }
    }

    private func loadProcessMetadata(pid: pid_t) -> (name: String, path: String) {
        var nameBuffer = [CChar](repeating: 0, count: Int(MAXCOMLEN * 4))
        let nameLength = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
        let name = nameLength > 0 ? String(cString: nameBuffer) : "Process \(pid)"

        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN * 4))
        let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        let path = pathLength > 0 ? String(cString: pathBuffer) : name
        return (name, path)
    }

    private func samplePower() -> PowerUsage {
        let telemetry = Self.sampleBatteryTelemetry()
        let thermals = sampleThermals()
        let energy = sampleEnergy(at: Date())
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as Array
        guard let source = sources.first,
              let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] else {
            return PowerUsage(
                batteryTemperatureCelsius: telemetry.batteryTemperatureCelsius,
                cycleCount: telemetry.cycleCount,
                voltageVolts: telemetry.voltageVolts,
                currentAmps: telemetry.currentAmps,
                systemPowerWatts: telemetry.systemPowerWatts,
                cpuTemperatureCelsius: thermals.cpu,
                gpuTemperatureCelsius: thermals.gpu,
                temperatureSensors: thermals.sensors,
                fans: thermals.fans,
                cpuPowerWatts: energy["CPU"],
                gpuPowerWatts: energy["GPU"],
                neuralEnginePowerWatts: energy["ANE"],
                memoryPowerWatts: energy["RAM"]
            )
        }

        let current = description[kIOPSCurrentCapacityKey] as? Double
        let maximum = description[kIOPSMaxCapacityKey] as? Double
        let percent: Double? = if let current, let maximum, maximum > 0 {
            current / maximum * 100
        } else {
            nil
        }
        let charging = description[kIOPSIsChargingKey] as? Bool ?? false
        let minutes = description[charging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey] as? Int

        return PowerUsage(
            batteryPercent: percent,
            isCharging: charging,
            timeRemainingMinutes: minutes.flatMap { $0 >= 0 ? $0 : nil },
            batteryTemperatureCelsius: telemetry.batteryTemperatureCelsius,
            cycleCount: telemetry.cycleCount,
            voltageVolts: telemetry.voltageVolts,
            currentAmps: telemetry.currentAmps,
            systemPowerWatts: telemetry.systemPowerWatts,
            cpuTemperatureCelsius: thermals.cpu,
            gpuTemperatureCelsius: thermals.gpu,
            temperatureSensors: thermals.sensors,
            fans: thermals.fans,
            cpuPowerWatts: energy["CPU"],
            gpuPowerWatts: energy["GPU"],
            neuralEnginePowerWatts: energy["ANE"],
            memoryPowerWatts: energy["RAM"]
        )
    }

    private func sampleThermals() -> (
        cpu: Double?,
        gpu: Double?,
        sensors: [TemperatureSensor],
        fans: [FanUsage]
    ) {
        let raw = MoniAppleSiliconTemperatureSensors() ?? [:]
        var sensors = raw.compactMap { name, number -> TemperatureSensor? in
            let value = number.doubleValue
            guard value >= 0, value <= 110 else { return nil }
            return TemperatureSensor(name: name, valueCelsius: value)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        var cpuValues = sensors
            .filter { $0.name.hasPrefix("pACC MTR Temp") || $0.name.hasPrefix("eACC MTR Temp") }
            .map(\.valueCelsius)
            .filter { $0 >= 10 }
        var gpuValues = sensors
            .filter { $0.name.hasPrefix("GPU MTR Temp") }
            .map(\.valueCelsius)
            .filter { $0 >= 10 }

        if cpuValues.isEmpty, hostIdentity?.chip.contains("M3") == true {
            let m3CPUKeys = [
                "Te05", "Te0L", "Te0P", "Te0S",
                "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E",
                "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E",
            ]
            cpuValues = appendSMCTemperatures(keys: m3CPUKeys, prefix: "CPU", to: &sensors)
        }
        if gpuValues.isEmpty, hostIdentity?.chip.contains("M3") == true {
            let m3GPUKeys = ["Tf14", "Tf18", "Tf19", "Tf1A", "Tf24", "Tf28", "Tf29", "Tf2A"]
            gpuValues = appendSMCTemperatures(keys: m3GPUKeys, prefix: "GPU", to: &sensors)
        }

        let fanCount = min(8, max(0, Int(smcReader.value(for: "FNum") ?? 0)))
        let fans = (0 ..< fanCount).compactMap { index -> FanUsage? in
            guard let speed = smcReader.value(for: "F\(index)Ac"), speed >= 0 else { return nil }
            let name: String
            if fanCount == 2 {
                name = index == 0 ? "Left fan" : "Right fan"
            } else {
                name = "Fan \(index + 1)"
            }
            return FanUsage(index: index, name: name, revolutionsPerMinute: speed)
        }

        return (
            average(cpuValues),
            average(gpuValues),
            sensors,
            fans
        )
    }

    private func appendSMCTemperatures(
        keys: [String],
        prefix: String,
        to sensors: inout [TemperatureSensor]
    ) -> [Double] {
        keys.enumerated().compactMap { index, key in
            guard let value = smcReader.value(for: key), value >= 10, value <= 110 else { return nil }
            sensors.append(TemperatureSensor(name: "\(prefix) core \(index + 1)", valueCelsius: value))
            return value
        }
    }

    private func sampleEnergy(at date: Date) -> [String: Double] {
        let counters = (MoniAppleSiliconEnergyCounters() ?? [:]).reduce(into: [String: Double]()) {
            $0[$1.key] = $1.value.doubleValue
        }
        defer { previousEnergyCounters = (counters, date) }
        guard let previousEnergyCounters,
              date > previousEnergyCounters.date
        else { return [:] }

        let elapsed = date.timeIntervalSince(previousEnergyCounters.date)
        return counters.reduce(into: [String: Double]()) { result, item in
            guard let previous = previousEnergyCounters.values[item.key], item.value >= previous else { return }
            let watts = (item.value - previous) / elapsed
            if watts.isFinite, watts >= 0 {
                result[item.key] = watts
            }
        }
    }

    private func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func sampleBatteryTelemetry() -> PowerUsage {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSmartBattery")
        )
        guard service != 0 else { return PowerUsage() }
        defer { IOObjectRelease(service) }

        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(
            service,
            &properties,
            kCFAllocatorDefault,
            0
        ) == KERN_SUCCESS,
            let values = properties?.takeRetainedValue() as? [String: Any]
        else { return PowerUsage() }

        let temperature = (values["Temperature"] as? NSNumber).map { $0.doubleValue / 100 }
        let cycleCount = (values["CycleCount"] as? NSNumber)?.intValue
        let voltage = (values["Voltage"] as? NSNumber).map { $0.doubleValue / 1_000 }
        let current = (values["InstantAmperage"] as? NSNumber).map { $0.doubleValue / 1_000 }
        let powerTelemetry = values["PowerTelemetryData"] as? [String: Any]
        let systemPower = (powerTelemetry?["SystemPowerIn"] as? NSNumber).map { $0.doubleValue / 1_000 }

        return PowerUsage(
            batteryTemperatureCelsius: temperature,
            cycleCount: cycleCount,
            voltageVolts: voltage,
            currentAmps: current,
            systemPowerWatts: systemPower
        )
    }

    private static func loadGPUDevices() -> [GPUDeviceInfo] {
        MTLCopyAllDevices().map { device in
            GPUDeviceInfo(
                registryID: device.registryID,
                name: device.name,
                isLowPower: device.isLowPower,
                isRemovable: device.isRemovable,
                hasUnifiedMemory: device.hasUnifiedMemory,
                recommendedMaxWorkingSetSize: device.recommendedMaxWorkingSetSize
            )
        }
    }

    private func sampleGPU(at date: Date) -> GPUUsage {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOAccelerator"),
            &iterator
        ) == KERN_SUCCESS else {
            return GPUUsage()
        }
        defer { IOObjectRelease(iterator) }

        var utilization: Double?
        var renderer: Double?
        var tiler: Double?
        var allocatedMemory: UInt64?
        var clientTimes: [Int32: UInt64] = [:]
        var service = IOIteratorNext(iterator)

        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            guard let value = IORegistryEntryCreateCFProperty(
                service,
                "PerformanceStatistics" as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() as? [String: Any] else {
                continue
            }

            utilization = max(utilization ?? 0, (value["Device Utilization %"] as? NSNumber)?.doubleValue ?? 0)
            renderer = max(renderer ?? 0, (value["Renderer Utilization %"] as? NSNumber)?.doubleValue ?? 0)
            tiler = max(tiler ?? 0, (value["Tiler Utilization %"] as? NSNumber)?.doubleValue ?? 0)
            if let bytes = value["Alloc system memory"] as? NSNumber {
                allocatedMemory = max(allocatedMemory ?? 0, bytes.uint64Value)
            }
            collectGPUClientTimes(from: service, into: &clientTimes)
        }

        return GPUUsage(
            utilizationPercent: utilization,
            rendererPercent: renderer,
            tilerPercent: tiler,
            allocatedMemoryBytes: allocatedMemory,
            clients: gpuClients(from: clientTimes, at: date)
        )
    }

    private func collectGPUClientTimes(
        from accelerator: io_registry_entry_t,
        into result: inout [Int32: UInt64]
    ) {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(
            accelerator,
            kIOServicePlane,
            IOOptionBits(kIORegistryIterateRecursively),
            &iterator
        ) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }

        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            defer {
                IOObjectRelease(entry)
                entry = IOIteratorNext(iterator)
            }
            guard let creator = IORegistryEntryCreateCFProperty(
                entry,
                "IOUserClientCreator" as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() as? String,
                let pid = gpuClientPID(from: creator),
                let usages = IORegistryEntryCreateCFProperty(
                    entry,
                    "AppUsage" as CFString,
                    kCFAllocatorDefault,
                    0
                )?.takeRetainedValue() as? [[String: Any]]
            else { continue }

            let total = usages.reduce(UInt64(0)) { partial, usage in
                partial + ((usage["accumulatedGPUTime"] as? NSNumber)?.uint64Value ?? 0)
            }
            result[pid, default: 0] += total
        }
    }

    private func gpuClientPID(from creator: String) -> Int32? {
        guard creator.hasPrefix("pid ") else { return nil }
        let start = creator.index(creator.startIndex, offsetBy: 4)
        let end = creator[start...].firstIndex(of: ",") ?? creator.endIndex
        return Int32(creator[start ..< end].trimmingCharacters(in: .whitespaces))
    }

    private func gpuClients(from times: [Int32: UInt64], at date: Date) -> [GPUClientUsage] {
        let elapsed = previousGPUClientDate.map { date.timeIntervalSince($0) } ?? 0
        defer {
            previousGPUClientTimes = times
            previousGPUClientDate = date
        }

        return times.compactMap { pid, current -> GPUClientUsage? in
            guard let previous = previousGPUClientTimes[pid], current >= previous else { return nil }
            let utilization = elapsed > 0
                ? min(100, Double(current - previous) / (elapsed * 1_000_000_000) * 100)
                : 0
            let process = cachedProcesses.first { $0.pid == pid }
            let name = process?.name ?? processMetadata[pid]?.name ?? loadProcessMetadata(pid: pid).name
            return GPUClientUsage(
                pid: pid,
                name: name,
                memoryBytes: process?.memoryBytes ?? 0,
                utilizationPercent: max(0, utilization)
            )
        }
        .sorted { lhs, rhs in
            if lhs.utilizationPercent == rhs.utilizationPercent {
                return lhs.memoryBytes > rhs.memoryBytes
            }
            return lhs.utilizationPercent > rhs.utilizationPercent
        }
    }

    private func sampleDockerStatus() -> DockerStatus {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let installations: [(path: String, provider: String)] = [
            ("/Applications/Docker.app", "Docker Desktop"),
            ("/Applications/OrbStack.app", "OrbStack"),
            ("/usr/local/bin/docker", "Docker CLI"),
            ("/opt/homebrew/bin/docker", "Docker CLI")
        ]
        let sockets: [(path: String, provider: String)] = [
            ("\(home)/.orbstack/run/docker.sock", "OrbStack"),
            ("\(home)/.docker/run/docker.sock", "Docker Desktop"),
            ("\(home)/Library/Containers/com.docker.docker/Data/docker-api.sock", "Docker Desktop"),
            ("/var/run/docker.sock", "Docker Engine")
        ]
        let installation = installations.first { FileManager.default.fileExists(atPath: $0.path) }
        let socket = sockets.first { FileManager.default.fileExists(atPath: $0.path) }
        let provider = socket?.provider ?? installation?.provider
        return DockerStatus(
            isInstalled: provider != nil,
            isRunning: socket != nil,
            installation: provider,
            socketPath: socket?.path
        )
    }

    private func sampleHost() -> HostDetails {
        guard let hostIdentity else { return HostDetails() }
        var averages = [Double](repeating: 0, count: 3)
        _ = getloadavg(&averages, 3)

        return HostDetails(
            name: hostIdentity.name,
            model: hostIdentity.model,
            chip: hostIdentity.chip,
            operatingSystem: hostIdentity.operatingSystem,
            kernel: hostIdentity.kernel,
            uptime: ProcessInfo.processInfo.systemUptime,
            loadAverages: averages,
            processorCount: hostIdentity.processorCount
        )
    }

    private static func loadHostIdentity() -> HostIdentity {
        var system = utsname()
        uname(&system)
        var releaseField = system.release
        let releaseCapacity = MemoryLayout.size(ofValue: releaseField)
        let release = withUnsafePointer(to: &releaseField) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: releaseCapacity) {
                String(cString: $0)
            }
        }
        return HostIdentity(
            name: ProcessInfo.processInfo.hostName,
            model: sysctlString("hw.model") ?? "Mac",
            chip: sysctlString("machdep.cpu.brand_string") ?? "Apple Silicon",
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            kernel: "Darwin \(release)",
            processorCount: ProcessInfo.processInfo.processorCount
        )
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
