import Darwin
import Foundation

nonisolated enum CondaCacheMaintenanceState: Sendable {
    case ready
    case protected
    case unavailable
    case failed
}

nonisolated struct CondaCacheMaintenanceSnapshot: Sendable {
    let paths: [String]
    let sizeBytes: UInt64
    let state: CondaCacheMaintenanceState
}

nonisolated enum CondaCacheCleanupOutcome: Sendable {
    case cleaned(reclaimedBytes: UInt64)
    case protected
    case unavailable
    case failed
}

nonisolated enum CondaCacheMaintenanceService {
    private static let commandTimeout: TimeInterval = 120

    static func scan() async -> CondaCacheMaintenanceSnapshot {
        let paths = cachePaths()
        guard let executable = condaExecutable(),
              commandSucceeds(executable, arguments: ["--version"], timeout: 5) else {
            return CondaCacheMaintenanceSnapshot(paths: paths, sizeBytes: 0, state: .unavailable)
        }
        guard !paths.contains(where: CleanupPreferences.isWhitelisted) else {
            return CondaCacheMaintenanceSnapshot(paths: paths, sizeBytes: 0, state: .protected)
        }

        var sizeBytes: UInt64 = 0
        for path in paths {
            var finalUpdate: DiskAnalysisUpdate?
            for await update in DiskAnalyzer.updates(for: path) {
                guard !Task.isCancelled else {
                    return CondaCacheMaintenanceSnapshot(paths: paths, sizeBytes: 0, state: .failed)
                }
                if update.isComplete { finalUpdate = update }
            }
            guard let finalUpdate, finalUpdate.unreadableItemCount == 0 else {
                return CondaCacheMaintenanceSnapshot(paths: paths, sizeBytes: 0, state: .failed)
            }
            let (sum, overflow) = sizeBytes.addingReportingOverflow(finalUpdate.scannedBytes)
            sizeBytes = overflow ? UInt64.max : sum
        }
        return CondaCacheMaintenanceSnapshot(paths: paths, sizeBytes: sizeBytes, state: .ready)
    }

    static func clean() async -> CondaCacheCleanupOutcome {
        let before = await scan()
        switch before.state {
        case .protected:
            return .protected
        case .unavailable:
            return .unavailable
        case .failed:
            return .failed
        case .ready:
            break
        }
        guard let executable = condaExecutable(),
              !cachePaths().contains(where: CleanupPreferences.isWhitelisted) else {
            return condaExecutable() == nil ? .unavailable : .protected
        }
        let succeeded = await Task.detached(priority: .utility) {
            commandSucceeds(
                executable,
                arguments: ["clean", "--yes", "--index-cache", "--tarballs", "--logfiles"],
                timeout: commandTimeout
            )
        }.value
        guard succeeded else { return .failed }

        let after = await scan()
        guard after.state == .ready else {
            return after.state == .protected ? .protected : .failed
        }
        return .cleaned(reclaimedBytes: before.sizeBytes > after.sizeBytes
            ? before.sizeBytes - after.sizeBytes
            : 0)
    }

    private static func cachePaths() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        return [
            home + "/.conda/pkgs",
            home + "/anaconda3/pkgs",
            home + "/miniconda3/pkgs",
            home + "/miniforge3/pkgs",
            home + "/mambaforge/pkgs"
        ].filter(isCurrentUserDirectory)
    }

    private static func condaExecutable() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        var paths = [
            "/opt/homebrew/bin/conda",
            "/usr/local/bin/conda",
            home + "/anaconda3/bin/conda",
            home + "/miniconda3/bin/conda",
            home + "/miniforge3/bin/conda",
            home + "/mambaforge/bin/conda"
        ]
        if let environmentPath = ProcessInfo.processInfo.environment["PATH"] {
            paths.append(contentsOf: environmentPath.split(separator: ":").map {
                URL(fileURLWithPath: String($0), isDirectory: true)
                    .appendingPathComponent("conda")
                    .standardizedFileURL.path
            })
        }
        var visited = Set<String>()
        return paths.first { candidate in
            let standardized = URL(fileURLWithPath: candidate).standardizedFileURL.path
            guard visited.insert(standardized).inserted else { return false }
            return FileManager.default.isExecutableFile(atPath: standardized)
        }
    }

    private static func commandSucceeds(
        _ executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) -> Bool {
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
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        return process.terminationReason == .exit && process.terminationStatus == 0
    }

    private static func isCurrentUserDirectory(_ path: String) -> Bool {
        var value = stat()
        return path.withCString { lstat($0, &value) } == 0
            && value.st_mode & S_IFMT == S_IFDIR
            && value.st_uid == getuid()
    }
}
