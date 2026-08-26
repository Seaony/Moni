import Darwin
import Foundation
import IOKit.ps
import Metal

final class SystemSampler {
    private struct CPUTicks {
        let user: UInt64
        let system: UInt64
        let idle: UInt64
        let nice: UInt64

        var total: UInt64 { user + system + idle + nice }
    }

    private var previousCPUTicks: [CPUTicks] = []
    private var previousNetworkBytes: (received: UInt64, sent: UInt64, date: Date)?
    private var previousProcessTimes: [Int32: UInt64] = [:]
    private var previousProcessDate: Date?

    func sample() -> SystemSnapshot {
        let now = Date()
        let processes = sampleProcesses(at: now)
        return SystemSnapshot(
            date: now,
            host: sampleHost(),
            cpu: sampleCPU(),
            memory: sampleMemory(),
            network: sampleNetwork(at: now),
            volumes: sampleVolumes(),
            processes: processes,
            power: samplePower(),
            gpuDevices: sampleGPUDevices(),
            docker: sampleDockerStatus()
        )
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
                user: UInt64(info[offset + Int(CPU_STATE_USER)]),
                system: UInt64(info[offset + Int(CPU_STATE_SYSTEM)]),
                idle: UInt64(info[offset + Int(CPU_STATE_IDLE)]),
                nice: UInt64(info[offset + Int(CPU_STATE_NICE)])
            )
        }

        defer { previousCPUTicks = current }
        guard previousCPUTicks.count == current.count else {
            return CPUUsage(perCore: Array(repeating: 0, count: current.count))
        }

        let deltas = zip(current, previousCPUTicks).map { current, previous in
            CPUTicks(
                user: current.user &- previous.user,
                system: current.system &- previous.system,
                idle: current.idle &- previous.idle,
                nice: current.nice &- previous.nice
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
            user: percent(aggregate.user + aggregate.nice, total: aggregate.total),
            system: percent(aggregate.system, total: aggregate.total),
            idle: percent(aggregate.idle, total: aggregate.total),
            perCore: perCore
        )
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

        return MemoryUsage(
            totalBytes: total,
            usedBytes: used,
            freeBytes: free,
            cachedBytes: cached,
            wiredBytes: wired,
            compressedBytes: compressed
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
                isActive: isActive
            )
            interfaces.append(interface)
            received += interface.receivedBytes
            sent += interface.sentBytes
        }

        let elapsed = previousNetworkBytes.map { date.timeIntervalSince($0.date) } ?? 0
        let download = elapsed > 0 ? Double(received &- (previousNetworkBytes?.received ?? received)) / elapsed : 0
        let upload = elapsed > 0 ? Double(sent &- (previousNetworkBytes?.sent ?? sent)) / elapsed : 0
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
            let previousTime = previousProcessTimes[pid] ?? totalTime
            let cpu = elapsed > 0 ? Double(totalTime &- previousTime) / (elapsed * 1_000_000_000) * 100 : 0

            var nameBuffer = [CChar](repeating: 0, count: Int(MAXCOMLEN * 4))
            let nameLength = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
            let name = nameLength > 0 ? String(cString: nameBuffer) : "Process \(pid)"

            var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN * 4))
            let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
            let path = pathLength > 0 ? String(cString: pathBuffer) : name

            usages.append(ProcessUsage(
                pid: pid,
                name: name,
                path: path,
                cpuPercent: max(0, cpu),
                memoryBytes: task.pti_resident_size
            ))
        }

        previousProcessTimes = currentTimes
        previousProcessDate = date
        return usages.sorted { lhs, rhs in
            if lhs.cpuPercent == rhs.cpuPercent { return lhs.memoryBytes > rhs.memoryBytes }
            return lhs.cpuPercent > rhs.cpuPercent
        }
    }

    private func samplePower() -> PowerUsage {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as Array
        guard let source = sources.first,
              let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] else {
            return PowerUsage()
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
            timeRemainingMinutes: minutes.flatMap { $0 >= 0 ? $0 : nil }
        )
    }

    private func sampleGPUDevices() -> [GPUDeviceInfo] {
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

    private func sampleDockerStatus() -> DockerStatus {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let installations = [
            "/Applications/Docker.app": "Docker Desktop",
            "/Applications/OrbStack.app": "OrbStack",
            "/usr/local/bin/docker": "Docker CLI",
            "/opt/homebrew/bin/docker": "Docker CLI"
        ]
        let sockets = [
            "\(home)/.docker/run/docker.sock",
            "\(home)/.orbstack/run/docker.sock",
            "\(home)/Library/Containers/com.docker.docker/Data/docker-api.sock",
            "/var/run/docker.sock"
        ]
        let installation = installations.first { FileManager.default.fileExists(atPath: $0.key) }
        let socket = sockets.first { FileManager.default.fileExists(atPath: $0) }
        return DockerStatus(
            isInstalled: installation != nil,
            isRunning: socket != nil,
            installation: installation?.value,
            socketPath: socket
        )
    }

    private func sampleHost() -> HostDetails {
        var averages = [Double](repeating: 0, count: 3)
        _ = getloadavg(&averages, 3)

        var system = utsname()
        uname(&system)
        var releaseField = system.release
        let releaseCapacity = MemoryLayout.size(ofValue: releaseField)
        let release = withUnsafePointer(to: &releaseField) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: releaseCapacity) {
                String(cString: $0)
            }
        }

        return HostDetails(
            name: ProcessInfo.processInfo.hostName,
            model: sysctlString("hw.model") ?? "Mac",
            chip: sysctlString("machdep.cpu.brand_string") ?? "Apple Silicon",
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            kernel: "Darwin \(release)",
            uptime: ProcessInfo.processInfo.systemUptime,
            loadAverages: averages,
            processorCount: ProcessInfo.processInfo.processorCount
        )
    }

    private func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
