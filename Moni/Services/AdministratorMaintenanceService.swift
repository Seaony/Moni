import Foundation
import Darwin

nonisolated enum SpotlightIndexStatus: Sendable {
    case enabled
    case disabled
    case unavailable
    case failed
}

nonisolated struct SystemMaintenanceSnapshot: Sendable {
    let spotlightStatus: SpotlightIndexStatus
}

nonisolated struct SystemMaintenanceResult: Sendable {
    let dnsCacheFlushed: Bool
    let spotlightStatus: SpotlightIndexStatus
}

nonisolated struct NetworkCacheRefreshResult: Sendable {
    let refreshed: Bool
}

nonisolated enum NetworkStackState: Sendable {
    case optimal
    case needsRefresh
    case activeVPN
    case unavailable
    case failed
}

nonisolated enum NetworkStackRefreshOutcome: Sendable {
    case alreadyOptimal
    case activeVPN
    case unavailable
    case inspectionFailed
    case authorizationCancelled
    case applied(routeFlushed: Bool, arpFlushed: Bool)
}

nonisolated enum PermissionRepairState: Sendable {
    case optimal
    case needsRepair
    case unavailable
}

nonisolated enum PermissionRepairOutcome: Sendable {
    case alreadyOptimal
    case unavailable
    case repaired
    case notCompleted
}

nonisolated enum SpotlightOptimizationState: Sendable {
    case optimal
    case slow
    case rebuilding
    case indexingDisabled
    case batteryPower
    case unavailable
    case failed
}

nonisolated enum SpotlightOptimizationOutcome: Sendable {
    case alreadyOptimal
    case indexingDisabled
    case batteryPower
    case unavailable
    case inspectionFailed
    case rebuildStarted
    case notCompleted
}

nonisolated enum PeriodicMaintenanceState: Sendable {
    case current
    case stale
    case missingLog
    case unavailable
    case failed
}

nonisolated struct PeriodicMaintenanceSnapshot: Sendable {
    let state: PeriodicMaintenanceState
    let ageDays: Int?
}

nonisolated enum PeriodicMaintenanceOutcome: Sendable {
    case alreadyCurrent
    case unavailable
    case inspectionFailed
    case triggered
    case notCompleted
}

nonisolated enum AdministratorMaintenanceService {
    private struct CommandOutput: Sendable {
        let status: Int32
        let output: String
        let timedOut: Bool
    }

    private static let scriptExecutable = "/usr/bin/osascript"
    private static let metadataUtilityExecutable = "/usr/bin/mdutil"
    private static let networkConfigurationExecutable = "/usr/sbin/scutil"
    private static let routeExecutable = "/sbin/route"
    private static let dnsCacheExecutable = "/usr/bin/dscacheutil"
    private static let arpExecutable = "/usr/sbin/arp"
    private static let diskUtilityExecutable = "/usr/sbin/diskutil"
    private static let powerManagementExecutable = "/usr/bin/pmset"
    private static let metadataSearchExecutable = "/usr/bin/mdfind"
    private static let periodicLogPath = "/var/log/daily.out"
    private static let periodicExecutablePaths = ["/usr/sbin/periodic", "/usr/bin/periodic"]

    static func scanSystemMaintenance() async -> SystemMaintenanceSnapshot {
        await Task.detached(priority: .utility) {
            SystemMaintenanceSnapshot(spotlightStatus: inspectSpotlightIndex())
        }.value
    }

    static func runSystemMaintenance() async -> SystemMaintenanceResult {
        await Task.detached(priority: .userInitiated) {
            let command = "/usr/bin/dscacheutil -flushcache && /usr/bin/killall -HUP mDNSResponder"
            let dnsCacheFlushed = runPrivileged(command, timeout: 30)
            return SystemMaintenanceResult(
                dnsCacheFlushed: dnsCacheFlushed,
                spotlightStatus: inspectSpotlightIndex()
            )
        }.value
    }

    static func refreshNetworkCache() async -> NetworkCacheRefreshResult {
        await Task.detached(priority: .userInitiated) {
            let command = "/usr/bin/dscacheutil -flushcache && /usr/bin/killall -HUP mDNSResponder"
            return NetworkCacheRefreshResult(
                refreshed: runPrivileged(command, timeout: 30)
            )
        }.value
    }

    static func scanNetworkStack() async -> NetworkStackState {
        await Task.detached(priority: .utility) {
            inspectNetworkStack()
        }.value
    }

    static func refreshNetworkStack() async -> NetworkStackRefreshOutcome {
        await Task.detached(priority: .userInitiated) {
            switch inspectNetworkStack() {
            case .optimal:
                return .alreadyOptimal
            case .activeVPN:
                return .activeVPN
            case .unavailable:
                return .unavailable
            case .failed:
                return .inspectionFailed
            case .needsRefresh:
                break
            }

            let command = """
            /sbin/route -n flush >/dev/null 2>&1; route_status=$?; \
            /usr/sbin/arp -a -d >/dev/null 2>&1; arp_status=$?; \
            printf '%s:%s' "$route_status" "$arp_status"
            """
            let result = runPrivilegedCommand(command, timeout: 30)
            guard result.status == 0 else { return .authorizationCancelled }
            let statuses = result.output
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: ":", omittingEmptySubsequences: false)
            guard statuses.count == 2,
                  let routeStatus = Int32(statuses[0]),
                  let arpStatus = Int32(statuses[1])
            else {
                return .inspectionFailed
            }
            return .applied(routeFlushed: routeStatus == 0, arpFlushed: arpStatus == 0)
        }.value
    }

    static func scanPermissionRepair() async -> PermissionRepairState {
        await Task.detached(priority: .utility) {
            inspectPermissionRepair()
        }.value
    }

    static func repairUserPermissions() async -> PermissionRepairOutcome {
        await Task.detached(priority: .userInitiated) {
            switch inspectPermissionRepair() {
            case .optimal:
                return .alreadyOptimal
            case .unavailable:
                return .unavailable
            case .needsRepair:
                let command = "/usr/sbin/diskutil resetUserPermissions / \(getuid())"
                return runPrivileged(command, timeout: 180) ? .repaired : .notCompleted
            }
        }.value
    }

    static func scanSpotlightOptimization() async -> SpotlightOptimizationState {
        await Task.detached(priority: .utility) {
            inspectSpotlightOptimization()
        }.value
    }

    static func optimizeSpotlight() async -> SpotlightOptimizationOutcome {
        await Task.detached(priority: .userInitiated) {
            switch inspectSpotlightOptimization() {
            case .optimal, .rebuilding:
                return .alreadyOptimal
            case .indexingDisabled:
                return .indexingDisabled
            case .batteryPower:
                return .batteryPower
            case .unavailable:
                return .unavailable
            case .failed:
                return .inspectionFailed
            case .slow:
                let command = "/usr/bin/mdutil -E / >/dev/null 2>&1"
                return runPrivileged(command, timeout: 30) ? .rebuildStarted : .notCompleted
            }
        }.value
    }

    static func scanPeriodicMaintenance() async -> PeriodicMaintenanceSnapshot {
        await Task.detached(priority: .utility) {
            inspectPeriodicMaintenance()
        }.value
    }

    static func runPeriodicMaintenance() async -> PeriodicMaintenanceOutcome {
        await Task.detached(priority: .userInitiated) {
            let snapshot = inspectPeriodicMaintenance()
            switch snapshot.state {
            case .current:
                return .alreadyCurrent
            case .unavailable:
                return .unavailable
            case .failed:
                return .inspectionFailed
            case .stale, .missingLog:
                guard let executable = periodicExecutable() else { return .unavailable }
                let command = "\(executable) daily weekly monthly"
                return runPrivileged(command, timeout: 300) ? .triggered : .notCompleted
            }
        }.value
    }

    private static func inspectPeriodicMaintenance() -> PeriodicMaintenanceSnapshot {
        guard periodicExecutable() != nil else {
            return PeriodicMaintenanceSnapshot(state: .unavailable, ageDays: nil)
        }
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: periodicLogPath) else {
            return PeriodicMaintenanceSnapshot(state: .missingLog, ageDays: nil)
        }
        guard let attributes = try? fileManager.attributesOfItem(atPath: periodicLogPath),
              let modificationDate = attributes[.modificationDate] as? Date
        else {
            return PeriodicMaintenanceSnapshot(state: .failed, ageDays: nil)
        }
        let ageDays = Int(Date().timeIntervalSince(modificationDate) / 86_400)
        return PeriodicMaintenanceSnapshot(
            state: ageDays < 7 ? .current : .stale,
            ageDays: ageDays
        )
    }

    private static func periodicExecutable() -> String? {
        periodicExecutablePaths.first(where: FileManager.default.isExecutableFile(atPath:))
    }

    private static func inspectSpotlightOptimization() -> SpotlightOptimizationState {
        let requiredExecutables = [
            metadataUtilityExecutable,
            metadataSearchExecutable,
            powerManagementExecutable,
            scriptExecutable
        ]
        guard requiredExecutables.allSatisfy(FileManager.default.isExecutableFile(atPath:)) else {
            return .unavailable
        }

        let statusResult = run(metadataUtilityExecutable, arguments: ["-s", "/"], timeout: 8)
        guard statusResult.status == 0 else { return .failed }
        if statusResult.output.localizedCaseInsensitiveContains("Indexing disabled") {
            return .indexingDisabled
        }
        let indexingEnabled = statusResult.output.localizedCaseInsensitiveContains("Indexing enabled")
            && !statusResult.output.localizedCaseInsensitiveContains("Indexing and searching disabled")
        guard indexingEnabled else { return .optimal }

        let powerResult = run(powerManagementExecutable, arguments: ["-g", "batt"], timeout: 8)
        guard powerResult.status == 0 else { return .failed }
        guard powerResult.output.contains("AC Power") else { return .batteryPower }

        var slowProbeCount = 0
        for probe in 0..<2 {
            let startedAt = Date()
            let result = run(
                metadataSearchExecutable,
                arguments: ["kMDItemFSName == 'Applications'"],
                timeout: 5
            )
            let elapsed = Date().timeIntervalSince(startedAt)
            if result.timedOut || (result.status == 0 && elapsed > 3) {
                slowProbeCount += 1
            } else if result.status != 0 {
                return .failed
            }
            if probe == 0 {
                Thread.sleep(forTimeInterval: 1)
            }
        }
        return slowProbeCount == 2 ? .slow : .optimal
    }

    private static func inspectPermissionRepair() -> PermissionRepairState {
        guard FileManager.default.isExecutableFile(atPath: diskUtilityExecutable),
              FileManager.default.isExecutableFile(atPath: scriptExecutable)
        else {
            return .unavailable
        }

        let fileManager = FileManager.default
        let homePath = fileManager.homeDirectoryForCurrentUser.path
        if let attributes = try? fileManager.attributesOfItem(atPath: homePath),
           let ownerID = attributes[.ownerAccountID] as? NSNumber,
           ownerID.uint32Value != getuid() {
            return .needsRepair
        }

        let paths = [
            homePath,
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library").path,
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Preferences")
                .path
        ]
        for path in paths where fileManager.fileExists(atPath: path) {
            if !fileManager.isWritableFile(atPath: path) {
                return .needsRepair
            }
        }
        return .optimal
    }

    private static func inspectNetworkStack() -> NetworkStackState {
        let requiredExecutables = [
            networkConfigurationExecutable,
            routeExecutable,
            dnsCacheExecutable,
            arpExecutable
        ]
        guard requiredExecutables.allSatisfy(FileManager.default.isExecutableFile(atPath:)) else {
            return .unavailable
        }

        let vpnResult = run(networkConfigurationExecutable, arguments: ["--nc", "list"], timeout: 8)
        guard vpnResult.status == 0 else { return .failed }
        let hasConnectedVPN = vpnResult.output
            .split(whereSeparator: \.isNewline)
            .contains { $0.hasPrefix("* (Connected)") }
        if hasConnectedVPN { return .activeVPN }

        let routeResult = run(routeExecutable, arguments: ["-n", "get", "default"], timeout: 8)
        guard routeResult.status <= 1 else { return .failed }
        if routeResult.status == 0 {
            let routeInterface = defaultRouteInterface(in: routeResult.output)
            let routeSuffix = routeInterface.dropFirst(4)
            if routeInterface.hasPrefix("utun"),
               !routeSuffix.isEmpty,
               routeSuffix.allSatisfy(\.isNumber) {
                return .activeVPN
            }
        }

        let dnsResult = run(
            dnsCacheExecutable,
            arguments: ["-q", "host", "-a", "name", "example.com"],
            timeout: 8
        )
        guard dnsResult.status <= 1 else { return .failed }
        return routeResult.status == 0 && dnsResult.status == 0 ? .optimal : .needsRefresh
    }

    private static func defaultRouteInterface(in output: String) -> String {
        for line in output.split(whereSeparator: \.isNewline) {
            let components = line.split(separator: ":", maxSplits: 1)
            guard components.count == 2,
                  components[0].trimmingCharacters(in: .whitespaces) == "interface"
            else { continue }
            return components[1].trimmingCharacters(in: .whitespaces)
        }
        return ""
    }

    private static func inspectSpotlightIndex() -> SpotlightIndexStatus {
        guard FileManager.default.isExecutableFile(atPath: metadataUtilityExecutable) else {
            return .unavailable
        }
        let result = run(
            metadataUtilityExecutable,
            arguments: ["-s", "/"],
            timeout: 8
        )
        guard result.status == 0 else { return .failed }
        return result.output.localizedCaseInsensitiveContains("Indexing disabled")
            ? .disabled
            : .enabled
    }

    private static func runPrivileged(
        _ shellCommand: String,
        timeout: TimeInterval
    ) -> Bool {
        runPrivilegedCommand(shellCommand, timeout: timeout).status == 0
    }

    private static func runPrivilegedCommand(
        _ shellCommand: String,
        timeout: TimeInterval
    ) -> CommandOutput {
        guard FileManager.default.isExecutableFile(atPath: scriptExecutable) else {
            return CommandOutput(status: -1, output: "", timedOut: false)
        }
        let escaped = shellCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        return run(scriptExecutable, arguments: ["-e", script], timeout: timeout)
    }

    private static func run(
        _ executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) -> CommandOutput {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        process.environment = environment
        do {
            try process.run()
        } catch {
            return CommandOutput(status: -1, output: error.localizedDescription, timedOut: false)
        }
        let timeoutWork = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeoutWork.cancel()
        return CommandOutput(
            status: process.terminationStatus,
            output: String(decoding: data, as: UTF8.self),
            timedOut: process.terminationReason == .uncaughtSignal
                && process.terminationStatus == SIGTERM
        )
    }
}
