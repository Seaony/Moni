import Darwin
import Foundation

nonisolated enum TartCacheMaintenanceState: Sendable {
    case ready
    case healthy
    case protected
    case busy
    case unavailable
    case failed
}

nonisolated struct TartCacheMaintenanceSnapshot: Sendable {
    let path: String
    let sizeBytes: UInt64
    let state: TartCacheMaintenanceState
}

nonisolated enum TartCachePruneOutcome: Sendable {
    case pruned(reclaimedBytes: UInt64)
    case noAction
    case protected
    case busy
    case unavailable
    case failed
}

nonisolated enum TartCacheMaintenanceService {
    private static let processExecutable = "/usr/bin/pgrep"
    private static let retentionDays = 30
    private static let commandTimeout: TimeInterval = 20

    static func scan() async -> TartCacheMaintenanceSnapshot {
        await snapshot()
    }

    static func prune() async -> TartCachePruneOutcome {
        let current = await snapshot()
        switch current.state {
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

        guard let executable = tartExecutable(), tartIsInactive() else {
            return tartExecutable() == nil ? .unavailable : .busy
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = [
            "prune", "--entries", "caches", "--older-than", String(retentionDays)
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return .failed
        }

        let timeout = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + commandTimeout, execute: timeout)
        process.waitUntilExit()
        let timedOut = timeout.isCancelled == false && process.terminationReason == .uncaughtSignal
        timeout.cancel()
        guard !timedOut, process.terminationReason == .exit, process.terminationStatus == 0 else {
            return .failed
        }

        let updated = await snapshot()
        switch updated.state {
        case .ready, .healthy:
            return .pruned(reclaimedBytes: current.sizeBytes > updated.sizeBytes
                ? current.sizeBytes - updated.sizeBytes
                : 0)
        case .protected:
            return .protected
        case .busy:
            return .busy
        case .unavailable:
            return .unavailable
        case .failed:
            return .failed
        }
    }

    private static func snapshot() async -> TartCacheMaintenanceSnapshot {
        let path = cachePath()
        guard FileManager.default.fileExists(atPath: path) else {
            return TartCacheMaintenanceSnapshot(path: path, sizeBytes: 0, state: .healthy)
        }
        guard isRealDirectory(at: path) else {
            return TartCacheMaintenanceSnapshot(path: path, sizeBytes: 0, state: .failed)
        }
        guard !CleanupPreferences.isWhitelisted(path) else {
            return TartCacheMaintenanceSnapshot(path: path, sizeBytes: 0, state: .protected)
        }
        guard tartExecutable() != nil else {
            return TartCacheMaintenanceSnapshot(path: path, sizeBytes: 0, state: .unavailable)
        }
        guard tartIsInactive() else {
            return TartCacheMaintenanceSnapshot(path: path, sizeBytes: 0, state: .busy)
        }

        var finalUpdate: DiskAnalysisUpdate?
        for await update in DiskAnalyzer.updates(for: path) {
            guard !Task.isCancelled else {
                return TartCacheMaintenanceSnapshot(path: path, sizeBytes: 0, state: .failed)
            }
            if update.isComplete { finalUpdate = update }
        }
        guard let finalUpdate, finalUpdate.unreadableItemCount == 0 else {
            return TartCacheMaintenanceSnapshot(path: path, sizeBytes: 0, state: .failed)
        }
        return TartCacheMaintenanceSnapshot(
            path: path,
            sizeBytes: finalUpdate.scannedBytes,
            state: finalUpdate.scannedBytes == 0 ? .healthy : .ready
        )
    }

    private static func tartIsInactive() -> Bool {
        guard FileManager.default.isExecutableFile(atPath: processExecutable) else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: processExecutable)
        process.arguments = ["-x", "tart"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        let timeout = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5, execute: timeout)
        process.waitUntilExit()
        timeout.cancel()
        return process.terminationReason == .exit && process.terminationStatus == 1
    }

    private static func tartExecutable() -> String? {
        var paths = ["/opt/homebrew/bin/tart", "/usr/local/bin/tart"]
        if let environmentPath = ProcessInfo.processInfo.environment["PATH"] {
            paths.append(contentsOf: environmentPath.split(separator: ":").map {
                URL(fileURLWithPath: String($0), isDirectory: true)
                    .appendingPathComponent("tart")
                    .standardizedFileURL.path
            })
        }
        var visited = Set<String>()
        return paths.first { path in
            let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
            guard visited.insert(standardized).inserted else { return false }
            return FileManager.default.isExecutableFile(atPath: standardized)
        }
    }

    private static func cachePath() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".tart/cache", isDirectory: true)
            .standardizedFileURL.path
    }

    private static func isRealDirectory(at path: String) -> Bool {
        var value = stat()
        return path.withCString { lstat($0, &value) } == 0
            && value.st_mode & S_IFMT == S_IFDIR
    }
}
