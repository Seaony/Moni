import Darwin
import Foundation

nonisolated enum NodeToolCacheKind: String, Sendable {
    case corepack
    case bun

    var displayName: String {
        switch self {
        case .corepack: "Corepack"
        case .bun: "Bun"
        }
    }
}

nonisolated enum NodeToolCacheMaintenanceState: Sendable {
    case ready
    case healthy
    case protected
    case busy
    case unavailable
    case failed
}

nonisolated struct NodeToolCacheMaintenanceItem: Identifiable, Sendable {
    let kind: NodeToolCacheKind
    let executable: String
    let path: String
    let sizeBytes: UInt64
    let isProtected: Bool

    var id: String { kind.rawValue + ":" + path }
}

nonisolated struct NodeToolCacheMaintenanceSnapshot: Sendable {
    let items: [NodeToolCacheMaintenanceItem]
    let state: NodeToolCacheMaintenanceState
}

nonisolated enum NodeToolCacheCleanupOutcome: Sendable {
    case cleaned(cacheCount: Int, reclaimedBytes: UInt64, failedCount: Int)
    case noAction
    case protected
    case busy
    case unavailable
    case failed
}

nonisolated enum NodeToolCacheMaintenanceService {
    private static let commandTimeout: TimeInterval = 120

    static func scan() async -> NodeToolCacheMaintenanceSnapshot {
        let tools = availableTools()
        guard !tools.isEmpty else {
            return NodeToolCacheMaintenanceSnapshot(items: [], state: .unavailable)
        }
        guard nodeToolsAreInactive() else {
            return NodeToolCacheMaintenanceSnapshot(items: [], state: .busy)
        }

        var items: [NodeToolCacheMaintenanceItem] = []
        for (kind, executable) in tools {
            guard let path = cachePath(for: kind, executable: executable) else {
                return NodeToolCacheMaintenanceSnapshot(items: [], state: .failed)
            }
            guard FileManager.default.fileExists(atPath: path) else { continue }
            guard isCurrentUserDirectory(path) else {
                return NodeToolCacheMaintenanceSnapshot(items: [], state: .failed)
            }

            var finalUpdate: DiskAnalysisUpdate?
            for await update in DiskAnalyzer.updates(for: path) {
                guard !Task.isCancelled else {
                    return NodeToolCacheMaintenanceSnapshot(items: [], state: .failed)
                }
                if update.isComplete { finalUpdate = update }
            }
            guard let finalUpdate, finalUpdate.unreadableItemCount == 0 else {
                return NodeToolCacheMaintenanceSnapshot(items: [], state: .failed)
            }
            guard finalUpdate.scannedBytes > 0 else { continue }
            items.append(NodeToolCacheMaintenanceItem(
                kind: kind,
                executable: executable,
                path: path,
                sizeBytes: finalUpdate.scannedBytes,
                isProtected: CleanupPreferences.isWhitelisted(path)
            ))
        }

        guard !items.isEmpty else {
            return NodeToolCacheMaintenanceSnapshot(items: [], state: .healthy)
        }
        return NodeToolCacheMaintenanceSnapshot(
            items: items.sorted { $0.kind.rawValue < $1.kind.rawValue },
            state: items.contains { !$0.isProtected } ? .ready : .protected
        )
    }

    static func clean(
        _ expected: NodeToolCacheMaintenanceSnapshot
    ) async -> NodeToolCacheCleanupOutcome {
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
        guard nodeToolsAreInactive() else { return .busy }

        var cleanedCount = 0
        var failedCount = 0
        for item in expected.items where !item.isProtected {
            guard nodeToolsAreInactive() else { return .busy }
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
            case .corepack: arguments = ["cache", "clean"]
            case .bun: arguments = ["pm", "cache", "rm"]
            }
            let succeeded = await Task.detached(priority: .utility) {
                runCommand(
                    item.executable,
                    arguments: arguments,
                    kind: item.kind,
                    cachePath: currentPath,
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
        let beforeBytes = totalSize(expected.items)
        let afterBytes = totalSize(after.items)
        return .cleaned(
            cacheCount: cleanedCount,
            reclaimedBytes: beforeBytes > afterBytes ? beforeBytes - afterBytes : 0,
            failedCount: failedCount
        )
    }

    private static func availableTools() -> [(NodeToolCacheKind, String)] {
        var tools: [(NodeToolCacheKind, String)] = []
        if let corepack = corepackExecutables().first(where: {
            toolIsUsable(.corepack, executable: $0)
        }) {
            tools.append((.corepack, corepack))
        }
        if let bun = bunExecutables().first(where: {
            toolIsUsable(.bun, executable: $0)
        }) {
            tools.append((.bun, bun))
        }
        return tools
    }

    private static func corepackExecutables() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        var candidates = baseExecutables(named: "corepack", extra: [
            home.appendingPathComponent(".volta/bin/corepack").path
        ])
        candidates.append(contentsOf: versionedExecutables(
            below: home.appendingPathComponent(".local/state/fnm_multishells", isDirectory: true),
            suffix: "bin/corepack"
        ))
        candidates.append(contentsOf: versionedExecutables(
            below: home.appendingPathComponent(".local/share/fnm/node-versions", isDirectory: true),
            suffix: "installation/bin/corepack"
        ))
        candidates.append(contentsOf: versionedExecutables(
            below: home.appendingPathComponent(".nvm/versions/node", isDirectory: true),
            suffix: "bin/corepack"
        ))
        candidates.append(contentsOf: versionedExecutables(
            below: home.appendingPathComponent(".local/share/mise/installs/node", isDirectory: true),
            suffix: "bin/corepack"
        ))
        return uniqueExecutables(candidates)
    }

    private static func bunExecutables() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        var candidates = baseExecutables(named: "bun", extra: [
            home.appendingPathComponent(".bun/bin/bun").path
        ])
        candidates.append(contentsOf: versionedExecutables(
            below: home.appendingPathComponent(".local/share/mise/installs/bun", isDirectory: true),
            suffix: "bin/bun"
        ))
        return uniqueExecutables(candidates)
    }

    private static func baseExecutables(named name: String, extra: [String]) -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        var candidates = [
            "/opt/homebrew/bin/" + name,
            "/usr/local/bin/" + name,
            home.appendingPathComponent(".local/bin/" + name).path
        ] + extra
        if let environmentPath = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: environmentPath.split(separator: ":").map {
                URL(fileURLWithPath: String($0), isDirectory: true)
                    .appendingPathComponent(name)
                    .standardizedFileURL.path
            })
        }
        return candidates
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

    private static func uniqueExecutables(_ candidates: [String]) -> [String] {
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

    private static func cachePath(for kind: NodeToolCacheKind, executable: String) -> String? {
        switch kind {
        case .corepack:
            let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
            let configured = ProcessInfo.processInfo.environment["COREPACK_HOME"]
            let reportedPath = configured?.isEmpty == false
                ? configured!
                : home + "/.cache/node/corepack"
            return safeCachePath(reportedPath)
        case .bun:
            return commandOutput(
                executable,
                arguments: ["pm", "cache"],
                kind: kind,
                timeout: 5
            ).flatMap(safeCachePath)
        }
    }

    private static func toolIsUsable(_ kind: NodeToolCacheKind, executable: String) -> Bool {
        commandOutput(executable, arguments: ["--version"], kind: kind, timeout: 5) != nil
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
        kind: NodeToolCacheKind,
        timeout: TimeInterval
    ) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = commandEnvironment(for: executable, kind: kind, cachePath: nil)
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
        kind: NodeToolCacheKind,
        cachePath: String,
        timeout: TimeInterval
    ) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = commandEnvironment(
            for: executable,
            kind: kind,
            cachePath: cachePath
        )
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

    private static func commandEnvironment(
        for executable: String,
        kind: NodeToolCacheKind,
        cachePath: String?
    ) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let directory = URL(fileURLWithPath: executable).deletingLastPathComponent().path
        let existingPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = directory + ":" + existingPath
        environment["COREPACK_ENABLE_DOWNLOAD_PROMPT"] = "0"
        if kind == .corepack, let cachePath {
            environment["COREPACK_HOME"] = cachePath
        }
        return environment
    }

    private static func nodeToolsAreInactive() -> Bool {
        processProbesAreInactive([
            ["-f", "(^|/)(corepack|bun)([[:space:]]|$)"]
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

    private static func totalSize(_ items: [NodeToolCacheMaintenanceItem]) -> UInt64 {
        items.reduce(UInt64(0)) { total, item in
            let (sum, overflow) = total.addingReportingOverflow(item.sizeBytes)
            return overflow ? UInt64.max : sum
        }
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
