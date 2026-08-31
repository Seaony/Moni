import Darwin
import Foundation

nonisolated enum GitHubCLICacheMaintenanceState: Sendable {
    case ready
    case healthy
    case protected
    case busy
    case unavailable
    case failed
}

nonisolated struct GitHubCLICacheMaintenanceSnapshot: Sendable {
    let path: String
    let sizeBytes: UInt64
    let state: GitHubCLICacheMaintenanceState
}

nonisolated enum GitHubCLICacheCleanupOutcome: Sendable {
    case cleaned(reclaimedBytes: UInt64)
    case noAction
    case protected
    case busy
    case unavailable
    case failed
}

nonisolated enum GitHubCLICacheMaintenanceService {
    private static let commandTimeout: TimeInterval = 120

    static func scan() async -> GitHubCLICacheMaintenanceSnapshot {
        guard ghExecutables().contains(where: ghSupportsCacheCleanup) else {
            return GitHubCLICacheMaintenanceSnapshot(path: "", sizeBytes: 0, state: .unavailable)
        }
        guard ghIsInactive() else {
            return GitHubCLICacheMaintenanceSnapshot(path: "", sizeBytes: 0, state: .busy)
        }
        guard let path = cachePath() else {
            return GitHubCLICacheMaintenanceSnapshot(path: "", sizeBytes: 0, state: .failed)
        }
        guard FileManager.default.fileExists(atPath: path) else {
            return GitHubCLICacheMaintenanceSnapshot(path: path, sizeBytes: 0, state: .healthy)
        }
        guard isCurrentUserDirectory(path), !isSymbolicLink(path) else {
            return GitHubCLICacheMaintenanceSnapshot(path: path, sizeBytes: 0, state: .failed)
        }
        guard !CleanupPreferences.isWhitelisted(path) else {
            return GitHubCLICacheMaintenanceSnapshot(path: path, sizeBytes: 0, state: .protected)
        }

        var finalUpdate: DiskAnalysisUpdate?
        for await update in DiskAnalyzer.updates(for: path) {
            guard !Task.isCancelled else {
                return GitHubCLICacheMaintenanceSnapshot(path: path, sizeBytes: 0, state: .failed)
            }
            if update.isComplete { finalUpdate = update }
        }
        guard let finalUpdate, finalUpdate.unreadableItemCount == 0 else {
            return GitHubCLICacheMaintenanceSnapshot(path: path, sizeBytes: 0, state: .failed)
        }
        return GitHubCLICacheMaintenanceSnapshot(
            path: path,
            sizeBytes: finalUpdate.scannedBytes,
            state: finalUpdate.scannedBytes > 0 ? .ready : .healthy
        )
    }

    static func clean(
        _ expected: GitHubCLICacheMaintenanceSnapshot
    ) async -> GitHubCLICacheCleanupOutcome {
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
        guard ghIsInactive() else { return .busy }
        guard let executable = ghExecutables().first(where: ghSupportsCacheCleanup) else {
            return .unavailable
        }
        guard let currentPath = cachePath(),
              pathsEqual(currentPath, expected.path),
              isCurrentUserDirectory(currentPath),
              !isSymbolicLink(currentPath) else {
            return .failed
        }
        guard !CleanupPreferences.isWhitelisted(currentPath) else { return .protected }
        guard ghIsInactive() else { return .busy }

        let parent = URL(fileURLWithPath: currentPath).deletingLastPathComponent().path
        let succeeded = await Task.detached(priority: .utility) {
            runCommand(
                executable,
                arguments: ["config", "clear-cache"],
                cacheParent: parent,
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

    private static func ghExecutables() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        var candidates = [
            "/opt/homebrew/bin/gh",
            "/usr/local/bin/gh",
            home.appendingPathComponent(".local/bin/gh").path
        ]
        if let environmentPath = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: environmentPath.split(separator: ":").map {
                URL(fileURLWithPath: String($0), isDirectory: true)
                    .appendingPathComponent("gh")
                    .standardizedFileURL.path
            })
        }
        for rootName in ["github-cli", "gh"] {
            candidates.append(contentsOf: versionedExecutables(
                below: home.appendingPathComponent(
                    ".local/share/mise/installs/" + rootName,
                    isDirectory: true
                ),
                suffix: "bin/gh"
            ))
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

    private static func ghSupportsCacheCleanup(_ executable: String) -> Bool {
        guard let path = cachePath() else { return false }
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        return runCommand(
            executable,
            arguments: ["config", "clear-cache", "--help"],
            cacheParent: parent,
            timeout: 5
        )
    }

    private static func cachePath() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let configured = ProcessInfo.processInfo.environment["XDG_CACHE_HOME"]
        let reportedParent = configured?.isEmpty == false ? configured! : home + "/.cache"
        guard reportedParent.hasPrefix("/"),
              !reportedParent.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !reportedParent.contains("//"),
              !reportedParent.split(separator: "/", omittingEmptySubsequences: false).contains("."),
              !reportedParent.split(separator: "/", omittingEmptySubsequences: false).contains("..") else {
            return nil
        }
        let lexicalParent = URL(fileURLWithPath: reportedParent, isDirectory: true)
            .standardizedFileURL.path
        guard !pathsEqual(lexicalParent, "/"), !pathsEqual(lexicalParent, home) else { return nil }
        if FileManager.default.fileExists(atPath: lexicalParent) {
            let physicalParent = URL(fileURLWithPath: lexicalParent, isDirectory: true)
                .resolvingSymlinksInPath().standardizedFileURL.path
            guard !pathsEqual(physicalParent, "/"),
                  !pathsEqual(physicalParent, home),
                  isCurrentUserDirectory(physicalParent) else {
                return nil
            }
            return URL(fileURLWithPath: physicalParent, isDirectory: true)
                .appendingPathComponent("gh", isDirectory: true)
                .path
        }
        return URL(fileURLWithPath: lexicalParent, isDirectory: true)
            .appendingPathComponent("gh", isDirectory: true)
            .path
    }

    private static func runCommand(
        _ executable: String,
        arguments: [String],
        cacheParent: String,
        timeout: TimeInterval
    ) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = commandEnvironment(for: executable, cacheParent: cacheParent)
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
        cacheParent: String
    ) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let directory = URL(fileURLWithPath: executable).deletingLastPathComponent().path
        let existingPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = directory + ":" + existingPath
        environment["XDG_CACHE_HOME"] = cacheParent
        return environment
    }

    private static func ghIsInactive() -> Bool {
        let executable = "/usr/bin/pgrep"
        guard FileManager.default.isExecutableFile(atPath: executable) else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-x", "gh"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationReason == .exit && process.terminationStatus == 1
    }

    private static func isCurrentUserDirectory(_ path: String) -> Bool {
        var value = stat()
        return path.withCString { lstat($0, &value) } == 0
            && value.st_mode & S_IFMT == S_IFDIR
            && value.st_uid == getuid()
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
