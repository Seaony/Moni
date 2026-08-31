import Darwin
import Foundation

nonisolated enum XcodeSimulatorMaintenanceState: Sendable {
    case ready
    case healthy
    case protected
    case unavailable
    case failed
}

nonisolated struct XcodeUnavailableSimulator: Identifiable, Sendable {
    let udid: String
    let name: String
    let runtime: String
    let path: String
    let sizeBytes: UInt64

    var id: String { udid }
}

nonisolated struct XcodeSimulatorMaintenanceSnapshot: Sendable {
    let items: [XcodeUnavailableSimulator]
    let state: XcodeSimulatorMaintenanceState
}

nonisolated enum XcodeSimulatorCleanupOutcome: Sendable {
    case cleaned(deviceCount: Int, reclaimedBytes: UInt64)
    case noAction
    case protected
    case unavailable
    case changed
    case failed
}

nonisolated enum XcodeSimulatorMaintenanceService {
    private static let xcrunExecutable = "/usr/bin/xcrun"
    private static let xcodeSelectExecutable = "/usr/bin/xcode-select"
    private static let commandTimeout: TimeInterval = 120

    static func scan() async -> XcodeSimulatorMaintenanceSnapshot {
        guard let developerDirectory = resolveDeveloperDirectory() else {
            return XcodeSimulatorMaintenanceSnapshot(items: [], state: .unavailable)
        }
        guard let data = commandData(
            arguments: ["simctl", "list", "devices", "unavailable", "-j"],
            developerDirectory: developerDirectory,
            timeout: 30
        ), let reportedItems = parseUnavailableDevices(data) else {
            return XcodeSimulatorMaintenanceSnapshot(items: [], state: .failed)
        }

        var items: [XcodeUnavailableSimulator] = []
        for reported in reportedItems {
            guard !Task.isCancelled else {
                return XcodeSimulatorMaintenanceSnapshot(items: [], state: .failed)
            }
            var sizeBytes: UInt64 = 0
            if FileManager.default.fileExists(atPath: reported.path) {
                guard simulatorDataDirectoryIsAllowed(reported.path) else {
                    return XcodeSimulatorMaintenanceSnapshot(items: [], state: .failed)
                }
                var finalUpdate: DiskAnalysisUpdate?
                for await update in DiskAnalyzer.updates(for: reported.path) {
                    guard !Task.isCancelled else {
                        return XcodeSimulatorMaintenanceSnapshot(items: [], state: .failed)
                    }
                    if update.isComplete { finalUpdate = update }
                }
                guard let finalUpdate, finalUpdate.unreadableItemCount == 0 else {
                    return XcodeSimulatorMaintenanceSnapshot(items: [], state: .failed)
                }
                sizeBytes = finalUpdate.scannedBytes
            }
            items.append(XcodeUnavailableSimulator(
                udid: reported.udid,
                name: reported.name,
                runtime: reported.runtime,
                path: reported.path,
                sizeBytes: sizeBytes
            ))
        }
        let sortedItems = items.sorted {
            if $0.sizeBytes != $1.sizeBytes { return $0.sizeBytes > $1.sizeBytes }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        if sortedItems.isEmpty {
            return XcodeSimulatorMaintenanceSnapshot(items: [], state: .healthy)
        }
        if sortedItems.contains(where: { CleanupPreferences.isWhitelisted($0.path) }) {
            return XcodeSimulatorMaintenanceSnapshot(items: sortedItems, state: .protected)
        }
        return XcodeSimulatorMaintenanceSnapshot(items: sortedItems, state: .ready)
    }

    static func deleteUnavailable(
        _ expected: XcodeSimulatorMaintenanceSnapshot
    ) async -> XcodeSimulatorCleanupOutcome {
        switch expected.state {
        case .healthy:
            return .noAction
        case .protected:
            return .protected
        case .unavailable:
            return .unavailable
        case .failed:
            return .failed
        case .ready:
            break
        }
        guard let developerDirectory = resolveDeveloperDirectory() else { return .unavailable }
        let current = await scan()
        switch current.state {
        case .protected:
            return .protected
        case .unavailable:
            return .unavailable
        case .failed:
            return .failed
        case .healthy:
            return .changed
        case .ready:
            break
        }
        guard Set(current.items.map(\.udid)) == Set(expected.items.map(\.udid)),
              current.items.allSatisfy({ !CleanupPreferences.isWhitelisted($0.path) }) else {
            return .changed
        }

        let succeeded = await Task.detached(priority: .utility) {
            runCommand(
                arguments: ["simctl", "delete", "unavailable"],
                developerDirectory: developerDirectory,
                timeout: commandTimeout
            )
        }.value
        guard succeeded else { return .failed }

        let after = await scan()
        guard after.state != .unavailable, after.state != .failed else { return .failed }
        let beforeBytes = totalSize(expected.items)
        let afterBytes = totalSize(after.items)
        let remainingIDs = Set(after.items.map(\.udid))
        let removedCount = expected.items.filter { !remainingIDs.contains($0.udid) }.count
        return .cleaned(
            deviceCount: removedCount,
            reclaimedBytes: beforeBytes > afterBytes ? beforeBytes - afterBytes : 0
        )
    }

    private static func parseUnavailableDevices(
        _ data: Data
    ) -> [(udid: String, name: String, runtime: String, path: String)]? {
        guard let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = response["devices"] as? [String: Any] else {
            return nil
        }
        let root = simulatorDevicesRoot()
        var items: [(String, String, String, String)] = []
        for (runtime, value) in devices {
            guard let entries = value as? [[String: Any]] else { return nil }
            for entry in entries {
                guard let udid = entry["udid"] as? String,
                      UUID(uuidString: udid) != nil,
                      let name = entry["name"] as? String,
                      !name.isEmpty else {
                    return nil
                }
                let path = URL(fileURLWithPath: root, isDirectory: true)
                    .appendingPathComponent(udid, isDirectory: true)
                    .standardizedFileURL.path
                items.append((udid, name, runtime, path))
            }
        }
        return items
    }

    private static func resolveDeveloperDirectory() -> String? {
        if let explicit = ProcessInfo.processInfo.environment["DEVELOPER_DIR"],
           !explicit.isEmpty {
            let normalized = URL(fileURLWithPath: explicit, isDirectory: true)
                .standardizedFileURL.path
            return developerDirectoryIsUsable(normalized) ? normalized : nil
        }
        guard FileManager.default.isExecutableFile(atPath: xcodeSelectExecutable),
              let selectedData = commandData(
                executable: xcodeSelectExecutable,
                arguments: ["-p"],
                environment: ProcessInfo.processInfo.environment,
                timeout: 5
              ), let selected = String(data: selectedData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !selected.isEmpty else {
            return nil
        }
        let standardized = URL(fileURLWithPath: selected, isDirectory: true).standardizedFileURL.path
        if !pathsEqual(standardized, "/Library/Developer/CommandLineTools") {
            return developerDirectoryIsUsable(standardized) ? standardized : nil
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            home.appendingPathComponent("Applications", isDirectory: true)
        ]
        var candidates: [String] = []
        for root in roots {
            guard let applications = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for application in applications {
                let name = application.lastPathComponent
                guard name.hasPrefix("Xcode"), name.hasSuffix(".app") else { continue }
                let developerDirectory = application
                    .appendingPathComponent("Contents/Developer", isDirectory: true)
                    .standardizedFileURL.path
                if developerDirectoryIsUsable(developerDirectory) {
                    candidates.append(developerDirectory)
                }
            }
        }
        let unique = Array(Set(candidates))
        return unique.count == 1 ? unique[0] : nil
    }

    private static func developerDirectoryIsUsable(_ path: String) -> Bool {
        let normalized = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
        guard isRealDirectory(normalized) else { return false }
        return runCommand(
            arguments: ["--find", "simctl"],
            developerDirectory: normalized,
            timeout: 5
        )
    }

    private static func commandData(
        arguments: [String],
        developerDirectory: String,
        timeout: TimeInterval
    ) -> Data? {
        var environment = ProcessInfo.processInfo.environment
        environment["DEVELOPER_DIR"] = developerDirectory
        return commandData(
            executable: xcrunExecutable,
            arguments: arguments,
            environment: environment,
            timeout: timeout
        )
    }

    private static func commandData(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) -> Data? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { return nil }
        return output.fileHandleForReading.readDataToEndOfFile()
    }

    private static func runCommand(
        arguments: [String],
        developerDirectory: String,
        timeout: TimeInterval
    ) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: xcrunExecutable) else { return false }
        var environment = ProcessInfo.processInfo.environment
        environment["DEVELOPER_DIR"] = developerDirectory
        let process = Process()
        process.executableURL = URL(fileURLWithPath: xcrunExecutable)
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        return process.terminationReason == .exit && process.terminationStatus == 0
    }

    private static func simulatorDataDirectoryIsAllowed(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        guard UUID(uuidString: url.lastPathComponent) != nil,
              pathsEqual(url.deletingLastPathComponent().path, simulatorDevicesRoot()),
              isRealDirectory(url.path),
              !isSymbolicLink(url.path) else {
            return false
        }
        var value = stat()
        return url.path.withCString { lstat($0, &value) } == 0 && value.st_uid == getuid()
    }

    private static func simulatorDevicesRoot() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/CoreSimulator/Devices", isDirectory: true)
            .standardizedFileURL.path
    }

    private static func totalSize(_ items: [XcodeUnavailableSimulator]) -> UInt64 {
        items.reduce(UInt64(0)) { total, item in
            let (sum, overflow) = total.addingReportingOverflow(item.sizeBytes)
            return overflow ? UInt64.max : sum
        }
    }

    private static func isRealDirectory(_ path: String) -> Bool {
        var value = stat()
        return path.withCString { lstat($0, &value) } == 0
            && value.st_mode & S_IFMT == S_IFDIR
    }

    private static func isSymbolicLink(_ path: String) -> Bool {
        var value = stat()
        return path.withCString { lstat($0, &value) } == 0
            && value.st_mode & S_IFMT == S_IFLNK
    }

    private static func pathsEqual(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: [.caseInsensitive, .literal]) == .orderedSame
    }
}
