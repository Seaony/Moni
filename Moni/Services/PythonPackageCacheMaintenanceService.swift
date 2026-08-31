import Darwin
import Foundation

nonisolated enum PythonPackageCacheKind: String, Sendable {
    case pip
    case uv

    var displayName: String {
        switch self {
        case .pip: "pip"
        case .uv: "uv"
        }
    }
}

nonisolated enum PythonPackageCacheMaintenanceState: Sendable {
    case ready
    case healthy
    case protected
    case busy
    case unavailable
    case failed
}

nonisolated struct PythonPackageCacheMaintenanceItem: Identifiable, Sendable {
    let kind: PythonPackageCacheKind
    let executable: String
    let path: String
    let sizeBytes: UInt64
    let isProtected: Bool

    var id: String { kind.rawValue + ":" + path }
}

nonisolated struct PythonPackageCacheMaintenanceSnapshot: Sendable {
    let items: [PythonPackageCacheMaintenanceItem]
    let state: PythonPackageCacheMaintenanceState
}

nonisolated enum PythonPackageCacheCleanupOutcome: Sendable {
    case cleaned(cacheCount: Int, reclaimedBytes: UInt64, failedCount: Int)
    case noAction
    case protected
    case busy
    case unavailable
    case failed
}

nonisolated enum PythonPackageCacheMaintenanceService {
    private static let commandTimeout: TimeInterval = 120

    static func scan() async -> PythonPackageCacheMaintenanceSnapshot {
        let tools = availableTools()
        guard !tools.isEmpty else {
            return PythonPackageCacheMaintenanceSnapshot(items: [], state: .unavailable)
        }
        guard pythonPackageToolsAreInactive() else {
            return PythonPackageCacheMaintenanceSnapshot(items: [], state: .busy)
        }

        var items: [PythonPackageCacheMaintenanceItem] = []
        for (kind, executable) in tools {
            guard let path = cachePath(for: kind, executable: executable) else {
                return PythonPackageCacheMaintenanceSnapshot(items: [], state: .failed)
            }
            guard FileManager.default.fileExists(atPath: path) else { continue }
            guard isCurrentUserDirectory(path) else {
                return PythonPackageCacheMaintenanceSnapshot(items: [], state: .failed)
            }

            var finalUpdate: DiskAnalysisUpdate?
            for await update in DiskAnalyzer.updates(for: path) {
                guard !Task.isCancelled else {
                    return PythonPackageCacheMaintenanceSnapshot(items: [], state: .failed)
                }
                if update.isComplete { finalUpdate = update }
            }
            guard let finalUpdate, finalUpdate.unreadableItemCount == 0 else {
                return PythonPackageCacheMaintenanceSnapshot(items: [], state: .failed)
            }
            guard finalUpdate.scannedBytes > 0 else { continue }
            items.append(PythonPackageCacheMaintenanceItem(
                kind: kind,
                executable: executable,
                path: path,
                sizeBytes: finalUpdate.scannedBytes,
                isProtected: CleanupPreferences.isWhitelisted(path)
            ))
        }

        guard !items.isEmpty else {
            return PythonPackageCacheMaintenanceSnapshot(items: [], state: .healthy)
        }
        return PythonPackageCacheMaintenanceSnapshot(
            items: items.sorted {
                if $0.kind != $1.kind { return $0.kind.rawValue < $1.kind.rawValue }
                return $0.path.localizedStandardCompare($1.path) == .orderedAscending
            },
            state: items.contains { !$0.isProtected } ? .ready : .protected
        )
    }

    static func clean(
        _ expected: PythonPackageCacheMaintenanceSnapshot
    ) async -> PythonPackageCacheCleanupOutcome {
        switch expected.state {
        case .healthy:
            return .noAction
        case .protected:
            return .protected
        case .busy:
            return .busy
        case .unavailable:
            return .unavailable
        case .failed:
            return .failed
        case .ready:
            break
        }
        guard pythonPackageToolsAreInactive() else { return .busy }

        var cleanedCount = 0
        var failedCount = 0
        for item in expected.items where !item.isProtected {
            guard pythonPackageToolsAreInactive() else { return .busy }
            guard FileManager.default.isExecutableFile(atPath: item.executable),
                  toolIsUsable(item.kind, executable: item.executable),
                  let currentPath = cachePath(for: item.kind, executable: item.executable),
                  pathsEqual(currentPath, item.path),
                  !CleanupPreferences.isWhitelisted(currentPath) else {
                failedCount += 1
                continue
            }
            let arguments: [String]
            switch item.kind {
            case .pip: arguments = ["cache", "purge"]
            case .uv: arguments = ["cache", "prune"]
            }
            let succeeded = await Task.detached(priority: .utility) {
                runCommand(
                    item.executable,
                    arguments: arguments,
                    timeout: commandTimeout
                )
            }.value
            if succeeded {
                cleanedCount += 1
            } else {
                failedCount += 1
            }
        }
        guard cleanedCount > 0 else {
            return failedCount > 0 ? .failed : .noAction
        }

        let after = await scan()
        guard after.state != .failed, after.state != .unavailable else { return .failed }
        return .cleaned(
            cacheCount: cleanedCount,
            reclaimedBytes: totalSize(expected.items) > totalSize(after.items)
                ? totalSize(expected.items) - totalSize(after.items)
                : 0,
            failedCount: failedCount
        )
    }

    private static func availableTools() -> [(PythonPackageCacheKind, String)] {
        var tools: [(PythonPackageCacheKind, String)] = []
        if let pip = executables(named: "pip3", extraCandidates: ["/usr/bin/pip3"])
            .first(where: { toolIsUsable(.pip, executable: $0) }) {
            tools.append((.pip, pip))
        }
        if let uv = executables(
            named: "uv",
            extraCandidates: [
                homePath(".local/bin/uv"),
                homePath(".cargo/bin/uv")
            ] + versionedExecutables(
                below: homeURL(".local/share/mise/installs/uv"),
                suffix: "uv"
            )
        ).first(where: { toolIsUsable(.uv, executable: $0) }) {
            tools.append((.uv, uv))
        }
        return tools
    }

    private static func cachePath(
        for kind: PythonPackageCacheKind,
        executable: String
    ) -> String? {
        let arguments: [String]
        switch kind {
        case .pip: arguments = ["cache", "dir"]
        case .uv: arguments = ["cache", "dir"]
        }
        return commandOutput(executable, arguments: arguments, timeout: 5)
            .flatMap(safeCachePath)
    }

    private static func toolIsUsable(
        _ kind: PythonPackageCacheKind,
        executable: String
    ) -> Bool {
        switch kind {
        case .pip:
            commandOutput(executable, arguments: ["--version"], timeout: 5) != nil
        case .uv:
            commandOutput(executable, arguments: ["--version"], timeout: 5) != nil
        }
    }

    private static func executables(
        named name: String,
        extraCandidates: [String]
    ) -> [String] {
        var candidates = [
            "/opt/homebrew/bin/" + name,
            "/usr/local/bin/" + name,
            homePath(".local/bin/" + name)
        ] + extraCandidates
        if let environmentPath = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: environmentPath.split(separator: ":").map {
                URL(fileURLWithPath: String($0), isDirectory: true)
                    .appendingPathComponent(name)
                    .standardizedFileURL.path
            })
        }
        var seen = Set<String>()
        return candidates.compactMap { candidate in
            let path = URL(fileURLWithPath: candidate).standardizedFileURL.path
            guard seen.insert(path).inserted,
                  FileManager.default.isExecutableFile(atPath: path) else {
                return nil
            }
            return path
        }
    }

    private static func versionedExecutables(below root: URL, suffix: String) -> [String] {
        guard isCurrentUserDirectory(root.path),
              let versions = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }
        return versions.map { $0.appendingPathComponent(suffix).standardizedFileURL.path }
    }

    private static func safeCachePath(_ reportedPath: String) -> String? {
        guard reportedPath.hasPrefix("/"),
              !reportedPath.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !reportedPath.contains("//"),
              !reportedPath.split(separator: "/", omittingEmptySubsequences: false).contains("."),
              !reportedPath.split(separator: "/", omittingEmptySubsequences: false).contains("..") else {
            return nil
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let lexical = URL(fileURLWithPath: reportedPath, isDirectory: true).standardizedFileURL.path
        guard pathIsInside(lexical, root: home) else { return nil }
        let excluded = ["/", home, home + "/Library", home + "/Library/Caches", home + "/.cache"]
        if FileManager.default.fileExists(atPath: lexical) {
            let physical = URL(fileURLWithPath: lexical, isDirectory: true)
                .resolvingSymlinksInPath().standardizedFileURL.path
            guard !excluded.contains(where: { pathsEqual(physical, $0) }),
                  pathIsInside(physical, root: home),
                  isCurrentUserDirectory(physical) else {
                return nil
            }
            return physical
        }
        return excluded.contains(where: { pathsEqual(lexical, $0) }) ? nil : lexical
    }

    private static func commandOutput(
        _ executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = commandEnvironment(for: executable)
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let timeoutWork = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeoutWork.cancel()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { return nil }
        let value = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty, !value.contains("\n"), !value.contains("\r") else {
            return nil
        }
        return value
    }

    private static func runCommand(
        _ executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = commandEnvironment(for: executable)
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

    private static func commandEnvironment(for executable: String) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let directory = URL(fileURLWithPath: executable).deletingLastPathComponent().path
        let existingPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = directory + ":" + existingPath
        return environment
    }

    private static func pythonPackageToolsAreInactive() -> Bool {
        processProbesAreInactive([
            ["-f", "(^|/)(uv|pip|pip3)([[:space:]]|$)"],
            ["-f", "(^|/)pip(_?3)?\\.[0-9]+([[:space:]]|$)"]
        ])
    }

    private static func processProbesAreInactive(_ probes: [[String]]) -> Bool {
        let executable = "/usr/bin/pgrep"
        guard FileManager.default.isExecutableFile(atPath: executable) else { return false }
        for arguments in probes {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                return false
            }
            process.waitUntilExit()
            guard process.terminationReason == .exit, process.terminationStatus == 1 else {
                return false
            }
        }
        return true
    }

    private static func totalSize(_ items: [PythonPackageCacheMaintenanceItem]) -> UInt64 {
        items.reduce(UInt64(0)) { total, item in
            let (sum, overflow) = total.addingReportingOverflow(item.sizeBytes)
            return overflow ? UInt64.max : sum
        }
    }

    private static func homePath(_ component: String) -> String {
        homeURL(component).path
    }

    private static func homeURL(_ component: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(component)
            .standardizedFileURL
    }

    private static func isCurrentUserDirectory(_ path: String) -> Bool {
        var value = stat()
        return path.withCString { lstat($0, &value) } == 0
            && value.st_mode & S_IFMT == S_IFDIR
            && value.st_uid == getuid()
    }

    private static func pathIsInside(_ path: String, root: String) -> Bool {
        path.lowercased().hasPrefix(root.lowercased() + "/")
    }

    private static func pathsEqual(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: [.caseInsensitive, .literal]) == .orderedSame
    }
}
