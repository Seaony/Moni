import Darwin
import CoreWLAN
import Foundation
import IOKit
import IOKit.ps
import Metal
import SystemConfiguration

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

    private struct NetworkMetadata {
        let primaryInterfaceName: String?
        let gateway: String?
        let interfaceKinds: [String: String]
        let wifi: WiFiUsage?
    }

    private struct GPUHardwareMetadata {
        let name: String?
        let vendor: String?
        let coreCount: Int?
        let metalSupport: String?
        let mainDisplayResolution: String?
        let mainDisplayRefreshRateHertz: Double?
    }

    private var previousCPUTicks: [CPUTicks] = []
    private var previousNetworkBytes: (received: UInt64, sent: UInt64, date: Date)?
    private var previousDiskCounters: (
        readBytes: UInt64,
        writtenBytes: UInt64,
        readOperations: UInt64,
        writeOperations: UInt64,
        date: Date
    )?
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
    private var cachedDriveHealth = DriveHealth()
    private var cachedProcesses: [ProcessUsage] = []
    private var cachedNetworkConnections: [NetworkConnectionUsage] = []
    private var cachedNetworkMetadata = NetworkMetadata(
        primaryInterfaceName: nil,
        gateway: nil,
        interfaceKinds: [:],
        wifi: nil
    )
    private var cachedPower = PowerUsage()
    private var cachedDocker = DockerStatus()
    private var lastProcessSample: Date?
    private var lastPeripheralSample: Date?
    private var lastConnectionSample: Date?

    private let processInterval: TimeInterval = 2
    private let peripheralInterval: TimeInterval = 5
    private let connectionInterval: TimeInterval = 5

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
            if cachedDriveHealth.smartStatus == nil {
                cachedDriveHealth = sampleDriveHealth()
            }
            cachedPower = samplePower()
            cachedDocker = sampleDockerStatus()
            cachedNetworkMetadata = Self.loadNetworkMetadata()
            lastPeripheralSample = now
        }

        return SystemSnapshot(
            date: now,
            host: sampleHost(),
            cpu: sampleCPU(),
            memory: sampleMemory(),
            network: sampleNetwork(at: now),
            diskActivity: sampleDiskActivity(at: now),
            driveHealth: cachedDriveHealth,
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
        if shouldRefresh(lastConnectionSample, at: date, interval: connectionInterval) {
            cachedNetworkConnections = sampleNetworkConnections()
            lastConnectionSample = date
        }

        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return NetworkUsage() }
        defer { freeifaddrs(pointer) }

        var interfaces: [NetworkInterfaceUsage] = []
        var ipv4Addresses: [String: String] = [:]
        var ipv6Addresses: [String: String] = [:]
        var received: UInt64 = 0
        var sent: UInt64 = 0
        var cursor: UnsafeMutablePointer<ifaddrs>? = first

        while let item = cursor?.pointee {
            defer { cursor = item.ifa_next }
            guard let address = item.ifa_addr else { continue }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                address,
                socklen_t(address.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 else { continue }
            let name = String(cString: item.ifa_name)
            let value = String(cString: host)
            if family == AF_INET {
                ipv4Addresses[name] = value
            } else if !value.hasPrefix("fe80:") {
                ipv6Addresses[name] = value
            }
        }

        cursor = first

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
            let wifiRate = cachedNetworkMetadata.wifi.flatMap {
                $0.interfaceName == name ? $0.transmitRateBitsPerSecond : nil
            }
            let interface = NetworkInterfaceUsage(
                name: name,
                kind: cachedNetworkMetadata.interfaceKinds[name] ?? Self.fallbackInterfaceKind(name),
                address: ipv4Addresses[name] ?? ipv6Addresses[name],
                receivedBytes: UInt64(usage.ifi_ibytes),
                sentBytes: UInt64(usage.ifi_obytes),
                isActive: isActive,
                linkSpeedBitsPerSecond: wifiRate ?? UInt64(usage.ifi_baudrate)
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
            primaryInterfaceName: cachedNetworkMetadata.primaryInterfaceName,
            gateway: cachedNetworkMetadata.gateway,
            wifi: cachedNetworkMetadata.wifi,
            interfaces: interfaces.sorted { lhs, rhs in
                if lhs.name == cachedNetworkMetadata.primaryInterfaceName { return true }
                if rhs.name == cachedNetworkMetadata.primaryInterfaceName { return false }
                if lhs.isActive != rhs.isActive { return lhs.isActive }
                return lhs.name < rhs.name
            },
            connections: cachedNetworkConnections
        )
    }

    private nonisolated static func loadNetworkMetadata() -> NetworkMetadata {
        let store = SCDynamicStoreCreate(nil, "Moni" as CFString, nil, nil)
        let globalIPv4 = store.flatMap {
            SCDynamicStoreCopyValue($0, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        }
        let primaryInterfaceName = globalIPv4?["PrimaryInterface"] as? String
        let gateway = globalIPv4?["Router"] as? String

        var kinds: [String: String] = [:]
        if let allInterfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] {
            for interface in allInterfaces {
                guard let name = SCNetworkInterfaceGetBSDName(interface) as String? else { continue }
                let displayName = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?
                let type = SCNetworkInterfaceGetInterfaceType(interface) as String?
                kinds[name] = displayName ?? type ?? fallbackInterfaceKind(name)
            }
        }

        let wifiInterface = primaryInterfaceName.flatMap {
            CWWiFiClient.shared().interface(withName: $0)
        } ?? CWWiFiClient.shared().interface()
        let wifi: WiFiUsage?
        if let wifiInterface,
           let interfaceName = wifiInterface.interfaceName,
           wifiInterface.powerOn() {
            let channel = wifiInterface.wlanChannel()
            let channelDescription = channel.map {
                "\($0.channelNumber) (\(channelBandName($0.channelBand.rawValue)))"
            }
            let signal = wifiInterface.rssiValue()
            wifi = WiFiUsage(
                interfaceName: interfaceName,
                physicalMode: wifiModeName(wifiInterface.activePHYMode().rawValue),
                networkName: wifiInterface.ssid(),
                signalStrengthDBm: signal < 0 ? signal : nil,
                channelDescription: channelDescription,
                transmitRateBitsPerSecond: UInt64(max(0, wifiInterface.transmitRate()) * 1_000_000)
            )
            kinds[interfaceName] = "Wi-Fi"
        } else {
            wifi = nil
        }

        return NetworkMetadata(
            primaryInterfaceName: primaryInterfaceName,
            gateway: gateway,
            interfaceKinds: kinds,
            wifi: wifi
        )
    }

    private nonisolated static func fallbackInterfaceKind(_ name: String) -> String {
        if name.hasPrefix("utun") { return "VPN" }
        if name.hasPrefix("bridge") { return "Bridge" }
        if name.hasPrefix("en") { return "Ethernet" }
        if name.hasPrefix("awdl") { return "Apple Wireless Direct Link" }
        if name.hasPrefix("llw") { return "Low-latency Wi-Fi" }
        return "Network interface"
    }

    private nonisolated static func wifiModeName(_ rawValue: Int) -> String {
        switch rawValue {
        case 7: "Wi-Fi 7"
        case 6: "Wi-Fi 6"
        case 5: "Wi-Fi 5"
        case 4: "Wi-Fi 4"
        case 3: "802.11g"
        case 2: "802.11b"
        case 1: "802.11a"
        default: "Wi-Fi"
        }
    }

    private nonisolated static func channelBandName(_ rawValue: Int) -> String {
        switch rawValue {
        case 3: "6 GHz"
        case 2: "5 GHz"
        case 1: "2.4 GHz"
        default: "Unknown band"
        }
    }

    private func sampleNetworkConnections() -> [NetworkConnectionUsage] {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        process.arguments = ["-L", "1", "-n", "-J", "bytes_in,bytes_out", "-x"]
        process.environment = [
            "NSUnbufferedIO": "YES",
            "LC_ALL": "en_US.UTF-8",
        ]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [] }
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        var currentProcess: (name: String, pid: Int32)?
        var connections: [NetworkConnectionUsage] = []
        output.enumerateLines { line, _ in
            let columns = line.split(separator: ",", omittingEmptySubsequences: false)
            guard columns.count >= 3 else { return }
            let label = String(columns[0])

            if label.hasPrefix("tcp") || label.hasPrefix("udp") {
                guard let currentProcess,
                      let separator = label.range(of: "<->")
                else { return }
                let localAndProtocol = label[..<separator.lowerBound]
                guard let firstSpace = localAndProtocol.firstIndex(of: " ") else { return }
                let transport = String(localAndProtocol[..<firstSpace]).uppercased()
                let local = String(localAndProtocol[localAndProtocol.index(after: firstSpace)...])
                let remote = String(label[separator.upperBound...])
                guard !remote.contains("*") else { return }
                let received = UInt64(columns[1]) ?? 0
                let sent = UInt64(columns[2]) ?? 0
                connections.append(NetworkConnectionUsage(
                    processName: currentProcess.name,
                    pid: currentProcess.pid,
                    localEndpoint: local,
                    remoteEndpoint: remote,
                    transport: transport,
                    receivedBytes: received,
                    sentBytes: sent
                ))
                return
            }

            guard let dot = label.lastIndex(of: "."),
                  let pid = Int32(label[label.index(after: dot)...])
            else { return }
            currentProcess = (String(label[..<dot]), pid)
        }

        return connections.sorted {
            ($0.receivedBytes + $0.sentBytes) > ($1.receivedBytes + $1.sentBytes)
        }
        .prefix(8)
        .map { $0 }
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
        var totalReadOperations: UInt64 = 0
        var totalWriteOperations: UInt64 = 0
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
                totalReadOperations += (statistics["Operations (Read)"] as? NSNumber)?.uint64Value ?? 0
                totalWriteOperations += (statistics["Operations (Write)"] as? NSNumber)?.uint64Value ?? 0
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }

        let elapsed = previousDiskCounters.map { date.timeIntervalSince($0.date) } ?? 0
        let priorRead = previousDiskCounters?.readBytes ?? totalRead
        let priorWritten = previousDiskCounters?.writtenBytes ?? totalWritten
        let priorReadOperations = previousDiskCounters?.readOperations ?? totalReadOperations
        let priorWriteOperations = previousDiskCounters?.writeOperations ?? totalWriteOperations
        let readDelta = totalRead >= priorRead ? totalRead - priorRead : 0
        let writeDelta = totalWritten >= priorWritten ? totalWritten - priorWritten : 0
        let readOperationDelta = totalReadOperations >= priorReadOperations ? totalReadOperations - priorReadOperations : 0
        let writeOperationDelta = totalWriteOperations >= priorWriteOperations ? totalWriteOperations - priorWriteOperations : 0
        previousDiskCounters = (totalRead, totalWritten, totalReadOperations, totalWriteOperations, date)
        return DiskActivity(
            readBytesPerSecond: elapsed > 0 ? Double(readDelta) / elapsed : 0,
            writeBytesPerSecond: elapsed > 0 ? Double(writeDelta) / elapsed : 0,
            readOperationsPerSecond: elapsed > 0 ? Double(readOperationDelta) / elapsed : 0,
            writeOperationsPerSecond: elapsed > 0 ? Double(writeOperationDelta) / elapsed : 0
        )
    }

    private func sampleDriveHealth() -> DriveHealth {
        guard let data = MoniNVMeSMARTData() else { return DriveHealth() }
        return DriveHealth(
            model: data["model"] as? String,
            smartStatus: data["smartStatus"] as? String,
            trimEnabled: (data["trimEnabled"] as? NSNumber)?.boolValue,
            temperatureCelsius: (data["temperatureCelsius"] as? NSNumber)?.doubleValue,
            totalWrittenBytes: (data["totalWrittenBytes"] as? NSNumber)?.uint64Value
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
                memoryBytes: task.pti_resident_size,
                threadCount: Int(task.pti_threadnum)
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
                isExternalPowerConnected: telemetry.isExternalPowerConnected,
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
            isExternalPowerConnected: telemetry.isExternalPowerConnected,
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
        let externalPowerConnected = (values["ExternalConnected"] as? NSNumber)?.boolValue ?? false
        let cycleCount = (values["CycleCount"] as? NSNumber)?.intValue
        let voltage = (values["Voltage"] as? NSNumber).map { $0.doubleValue / 1_000 }
        let current = (values["InstantAmperage"] as? NSNumber).map { $0.doubleValue / 1_000 }
        let powerTelemetry = values["PowerTelemetryData"] as? [String: Any]
        let systemPower = (powerTelemetry?["SystemPowerIn"] as? NSNumber).map { $0.doubleValue / 1_000 }

        return PowerUsage(
            isExternalPowerConnected: externalPowerConnected,
            batteryTemperatureCelsius: temperature,
            cycleCount: cycleCount,
            voltageVolts: voltage,
            currentAmps: current,
            systemPowerWatts: systemPower
        )
    }

    private static func loadGPUDevices() -> [GPUDeviceInfo] {
        let metadata = loadGPUHardwareMetadata()
        return MTLCopyAllDevices().map { device in
            GPUDeviceInfo(
                registryID: device.registryID,
                name: device.name,
                vendor: metadata?.vendor ?? (device.name.hasPrefix("Apple") ? "Apple" : "Unknown"),
                coreCount: metadata?.name == device.name ? metadata?.coreCount : nil,
                metalSupport: metadata?.name == device.name ? metadata?.metalSupport : nil,
                hasUnifiedMemory: device.hasUnifiedMemory,
                unifiedMemoryBytes: device.hasUnifiedMemory ? ProcessInfo.processInfo.physicalMemory : nil,
                mainDisplayResolution: metadata?.name == device.name ? metadata?.mainDisplayResolution : nil,
                mainDisplayRefreshRateHertz: metadata?.name == device.name ? metadata?.mainDisplayRefreshRateHertz : nil
            )
        }
    }

    private static func loadGPUHardwareMetadata() -> GPUHardwareMetadata? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPDisplaysDataType", "-json", "-detailLevel", "mini"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let adapters = root["SPDisplaysDataType"] as? [[String: Any]],
                  let adapter = adapters.first else { return nil }

            let name = adapter["sppci_model"] as? String ?? adapter["_name"] as? String
            let vendorToken = adapter["spdisplays_vendor"] as? String
            let vendor = vendorToken?.localizedCaseInsensitiveContains("apple") == true ? "Apple" : vendorToken
            let coreCount = (adapter["sppci_cores"] as? String).flatMap(Int.init)
            let metalSupport = (adapter["spdisplays_mtlgpufamilysupport"] as? String).flatMap { value in
                value.last.flatMap(\.wholeNumberValue).map { "Metal \($0)" }
            }
            let displays = adapter["spdisplays_ndrvs"] as? [[String: Any]] ?? []
            let mainDisplay = displays.first { $0["spdisplays_main"] as? String == "spdisplays_yes" }
                ?? displays.first
            let resolution = mainDisplay?["_spdisplays_pixels"] as? String
            let refreshRate = (mainDisplay?["_spdisplays_resolution"] as? String).flatMap(refreshRate(from:))
            return GPUHardwareMetadata(
                name: name,
                vendor: vendor,
                coreCount: coreCount,
                metalSupport: metalSupport,
                mainDisplayResolution: resolution,
                mainDisplayRefreshRateHertz: refreshRate
            )
        } catch {
            return nil
        }
    }

    private static func refreshRate(from resolution: String) -> Double? {
        guard let marker = resolution.range(of: " @ "),
              let suffix = resolution[marker.upperBound...].split(separator: "H").first else { return nil }
        return Double(suffix)
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
        let existingSockets = sockets.filter { FileManager.default.fileExists(atPath: $0.path) }
        let connectedSocket = existingSockets.first { Self.canConnect(toUnixSocket: $0.path) }
        let detectedSocket = connectedSocket ?? existingSockets.first
        let provider = detectedSocket?.provider ?? installation?.provider
        return DockerStatus(
            isInstalled: provider != nil,
            isRunning: connectedSocket != nil,
            installation: provider,
            socketPath: detectedSocket?.path
        )
    }

    private nonisolated static func canConnect(toUnixSocket path: String) -> Bool {
        let pathBytes = path.utf8CString
        var address = sockaddr_un()
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= pathCapacity else { return false }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }

        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: pathCapacity) { destination in
                pathBytes.withUnsafeBufferPointer { source in
                    destination.update(from: source.baseAddress!, count: pathBytes.count)
                }
            }
        }
        let addressLength = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count)
        address.sun_len = UInt8(addressLength)
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, addressLength) == 0
            }
        }
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
