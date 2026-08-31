import Darwin
import Foundation

nonisolated enum NpmCacheMaintenanceState: Sendable {
    case ready
    case healthy
    case protected
    case busy
    case unavailable
    case failed
}

nonisolated struct NpmCacheMaintenanceSnapshot: Sendable {
    let path: String
    let sizeBytes: UInt64
    let state: NpmCacheMaintenanceState
}

nonisolated enum NpmCacheCleanupOutcome: Sendable {
    case cleaned(reclaimedBytes: UInt64)
    case noAction
    case protected
    case busy
    case unavailable
    case failed
}

nonisolated enum NpmCacheMaintenanceService {
    private static let commandTimeout: TimeInterval = 120

    static func scan() async -> NpmCacheMaintenanceSnapshot {
        guard let executable = npmExecutables().first(where: npmIsUsable) else {
            return NpmCacheMaintenanceSnapshot(path: "", sizeBytes: 0, state: .unavailable)
        }
        guard npmIsInactive() else {
            return NpmCacheMaintenanceSnapshot(path: "", sizeBytes: 0, state: .busy)
        }
        guard let reportedPath = commandOutput(
            executable,
            arguments: ["config", "get", "cache"],
            timeout: 5
        ), let path = safeCachePath(reportedPath) else {
            return NpmCacheMaintenanceSnapshot(path: "", sizeBytes: 0, state: .failed)
        }
        guard !CleanupPreferences.isWhitelisted(path) else {
            return NpmCacheMaintenanceSnapshot(path: path, sizeBytes: 0, state: .protected)
        }
        guard FileManager.default.fileExists(atPath: path) else {
            return NpmCacheMaintenanceSnapshot(path: path, sizeBytes: 0, state: .healthy)
        }
        guard isCurrentUserDirectory(path) else {
            return NpmCacheMaintenanceSnapshot(path: path, sizeBytes: 0, state: .failed)
        }

        var finalUpdate: DiskAnalysisUpdate?
        for await update in DiskAnalyzer.updates(for: path) {
            guard !Task.isCancelled else {
                return NpmCacheMaintenanceSnapshot(path: path, sizeBytes: 0, state: .failed)
            }
            if update.isComplete { finalUpdate = update }
        }
        guard let finalUpdate, finalUpdate.unreadableItemCount == 0 else {
            return NpmCacheMaintenanceSnapshot(path: path, sizeBytes: 0, state: .failed)
        }
        return NpmCacheMaintenanceSnapshot(
            path: path,
            sizeBytes: finalUpdate.scannedBytes,
            state: finalUpdate.scannedBytes > 0 ? .ready : .healthy
        )
    }

    static func clean(_ expected: NpmCacheMaintenanceSnapshot) async -> NpmCacheCleanupOutcome {
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
        guard npmIsInactive() else { return .busy }
        guard let executable = npmExecutables().first(where: npmIsUsable) else { return .unavailable }
        guard let currentPath = commandOutput(
            executable,
            arguments: ["config", "get", "cache"],
            timeout: 5
        ).flatMap(safeCachePath), pathsEqual(currentPath, expected.path) else {
            return .failed
        }
        guard !CleanupPreferences.isWhitelisted(currentPath) else { return .protected }
        guard npmIsInactive() else { return .busy }

        let succeeded = await Task.detached(priority: .utility) {
            runCommand(
                executable,
                arguments: ["cache", "clean", "--force"],
                timeout: commandTimeout
            )
        }.value
        guard succeeded else { return .failed }

        let after = await scan()
        guard after.state != .unavailable, after.state != .failed else { return .failed }
        return .cleaned(
            reclaimedBytes: expected.sizeBytes > after.sizeBytes
                ? expected.sizeBytes - after.sizeBytes
                : 0
        )
    }

    private static func npmExecutables() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        var candidates = [
            "/opt/homebrew/bin/npm",
            "/usr/local/bin/npm",
            home.appendingPathComponent(".local/bin/npm").path,
            home.appendingPathComponent(".volta/bin/npm").path
        ]
        if let environmentPath = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: environmentPath.split(separator: ":").map {
                URL(fileURLWithPath: String($0), isDirectory: true)
                    .appendingPathComponent("npm")
                    .standardizedFileURL.path
            })
        }
        candidates.append(contentsOf: versionedExecutables(
            below: home.appendingPathComponent(".local/state/fnm_multishells", isDirectory: true),
            suffix: "bin/npm"
        ))
        candidates.append(contentsOf: versionedExecutables(
            below: home.appendingPathComponent(".local/share/fnm/node-versions", isDirectory: true),
            suffix: "installation/bin/npm"
        ))
        candidates.append(contentsOf: versionedExecutables(
            below: home.appendingPathComponent(".nvm/versions/node", isDirectory: true),
            suffix: "bin/npm"
        ))
        candidates.append(contentsOf: versionedExecutables(
            below: home.appendingPathComponent(".local/share/mise/installs/node", isDirectory: true),
            suffix: "bin/npm"
        ))

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
        return versions.map {
            $0.appendingPathComponent(suffix).standardizedFileURL.path
        }
    }

    private static func npmIsUsable(_ executable: String) -> Bool {
        commandOutput(executable, arguments: ["--version"], timeout: 5) != nil
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
        if FileManager.default.fileExists(atPath: lexical) {
            let physical = URL(fileURLWithPath: lexical, isDirectory: true)
                .resolvingSymlinksInPath().standardizedFileURL.path
            let excluded = ["/", home, home + "/Library", home + "/Library/Caches", home + "/.cache"]
            guard !excluded.contains(where: { pathsEqual(physical, $0) }),
                  pathIsInside(physical, root: home),
                  isCurrentUserDirectory(physical) else {
                return nil
            }
            return physical
        }
        let excluded = ["/", home, home + "/Library", home + "/Library/Caches", home + "/.cache"]
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

    private static func npmIsInactive() -> Bool {
        processProbesAreInactive([
            ["-f", "(^|/)(npm|npx)([[:space:]]|$)"],
            ["-f", "/(npm|npx)-cli\\.js([[:space:]]|$)"]
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
