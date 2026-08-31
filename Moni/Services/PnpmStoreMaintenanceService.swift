import Darwin
import Foundation

nonisolated enum PnpmStoreMaintenanceState: Sendable {
    case ready
    case healthy
    case protected
    case busy
    case unavailable
    case failed
}

nonisolated struct PnpmStoreMaintenanceItem: Identifiable, Sendable {
    let executable: String
    let path: String
    let sizeBytes: UInt64
    let isProtected: Bool

    var id: String { path }
}

nonisolated struct PnpmStoreMaintenanceSnapshot: Sendable {
    let stores: [PnpmStoreMaintenanceItem]
    let state: PnpmStoreMaintenanceState
}

nonisolated enum PnpmStorePruneOutcome: Sendable {
    case pruned(storeCount: Int, reclaimedBytes: UInt64, failedCount: Int)
    case noAction
    case protected
    case busy
    case unavailable
    case failed
}

nonisolated enum PnpmStoreMaintenanceService {
    private static let commandTimeout: TimeInterval = 120

    static func scan() async -> PnpmStoreMaintenanceSnapshot {
        let executables = pnpmExecutables()
        guard !executables.isEmpty else {
            return PnpmStoreMaintenanceSnapshot(stores: [], state: .unavailable)
        }
        guard pnpmIsInactive() else {
            return PnpmStoreMaintenanceSnapshot(stores: [], state: .busy)
        }

        var stores: [PnpmStoreMaintenanceItem] = []
        var seenPaths = Set<String>()
        for executable in executables {
            guard commandOutput(executable, arguments: ["--version"], timeout: 5) != nil,
                  let reportedPath = commandOutput(
                    executable,
                    arguments: ["store", "path"],
                    timeout: 5
                  ),
                  let path = safeStorePath(reportedPath),
                  seenPaths.insert(path).inserted else {
                continue
            }
            var finalUpdate: DiskAnalysisUpdate?
            for await update in DiskAnalyzer.updates(for: path) {
                guard !Task.isCancelled else {
                    return PnpmStoreMaintenanceSnapshot(stores: [], state: .failed)
                }
                if update.isComplete { finalUpdate = update }
            }
            guard let finalUpdate, finalUpdate.unreadableItemCount == 0 else {
                return PnpmStoreMaintenanceSnapshot(stores: [], state: .failed)
            }
            stores.append(PnpmStoreMaintenanceItem(
                executable: executable,
                path: path,
                sizeBytes: finalUpdate.scannedBytes,
                isProtected: CleanupPreferences.isWhitelisted(path)
            ))
        }
        guard !stores.isEmpty else {
            return PnpmStoreMaintenanceSnapshot(stores: [], state: .healthy)
        }
        let state: PnpmStoreMaintenanceState = stores.contains { !$0.isProtected }
            ? .ready
            : .protected
        return PnpmStoreMaintenanceSnapshot(
            stores: stores.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending },
            state: state
        )
    }

    static func prune(_ expected: PnpmStoreMaintenanceSnapshot) async -> PnpmStorePruneOutcome {
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
        guard pnpmIsInactive() else { return .busy }

        var prunedCount = 0
        var failedCount = 0
        for store in expected.stores where !store.isProtected {
            guard pnpmIsInactive() else { return .busy }
            guard !CleanupPreferences.isWhitelisted(store.path),
                  let currentPath = commandOutput(
                    store.executable,
                    arguments: ["store", "path"],
                    timeout: 5
                  ).flatMap(safeStorePath),
                  currentPath == store.path else {
                failedCount += 1
                continue
            }
            let succeeded = await runPrune(executable: store.executable)
            if succeeded {
                prunedCount += 1
            } else {
                failedCount += 1
            }
        }
        guard prunedCount > 0 else {
            return failedCount > 0 ? .failed : .noAction
        }

        let after = await scan()
        let beforeBytes = expected.stores.reduce(UInt64(0)) { total, store in
            let (sum, overflow) = total.addingReportingOverflow(store.sizeBytes)
            return overflow ? UInt64.max : sum
        }
        let afterBytes = after.stores.reduce(UInt64(0)) { total, store in
            let (sum, overflow) = total.addingReportingOverflow(store.sizeBytes)
            return overflow ? UInt64.max : sum
        }
        return .pruned(
            storeCount: prunedCount,
            reclaimedBytes: beforeBytes > afterBytes ? beforeBytes - afterBytes : 0,
            failedCount: failedCount
        )
    }

    private static func runPrune(executable: String) async -> Bool {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["store", "prune"]
            process.environment = commandEnvironment()
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                return false
            }
            let deadline = Date().addingTimeInterval(commandTimeout)
            while process.isRunning, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            return process.terminationReason == .exit && process.terminationStatus == 0
        }.value
    }

    private static func pnpmExecutables() -> [String] {
        var candidates = ["/opt/homebrew/bin/pnpm", "/usr/local/bin/pnpm"]
        if let environmentPath = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: environmentPath.split(separator: ":").map {
                URL(fileURLWithPath: String($0), isDirectory: true)
                    .appendingPathComponent("pnpm")
                    .standardizedFileURL.path
            })
        }
        let miseRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/mise/installs/pnpm", isDirectory: true)
            .standardizedFileURL
        if let versions = try? FileManager.default.contentsOfDirectory(
            at: miseRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            candidates.append(contentsOf: versions.map {
                $0.appendingPathComponent("pnpm").standardizedFileURL.path
            })
        }

        var seen = Set<String>()
        return candidates.compactMap { candidate in
            let standardized = URL(fileURLWithPath: candidate).standardizedFileURL.path
            guard seen.insert(standardized).inserted,
                  FileManager.default.isExecutableFile(atPath: standardized) else {
                return nil
            }
            return standardized
        }
    }

    private static func safeStorePath(_ reportedPath: String) -> String? {
        guard reportedPath.hasPrefix("/"),
              !reportedPath.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !reportedPath.contains("//"),
              !reportedPath.split(separator: "/", omittingEmptySubsequences: false).contains("."),
              !reportedPath.split(separator: "/", omittingEmptySubsequences: false).contains("..") else {
            return nil
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let lexical = URL(fileURLWithPath: reportedPath, isDirectory: true).standardizedFileURL.path
        let physical = URL(fileURLWithPath: lexical, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL.path
        let excluded = ["/", home, home + "/Library", home + "/Library/pnpm"]
        guard !excluded.contains(where: { pathsEqual(physical, $0) }),
              isCurrentUserDirectory(physical) else {
            return nil
        }
        return physical
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
        process.environment = commandEnvironment()
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
        let value = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty, !value.contains("\n"), !value.contains("\r") else {
            return nil
        }
        return value
    }

    private static func commandEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["COREPACK_ENABLE_DOWNLOAD_PROMPT"] = "0"
        return environment
    }

    private static func pnpmIsInactive() -> Bool {
        let executable = "/usr/bin/pgrep"
        guard FileManager.default.isExecutableFile(atPath: executable) else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-f", "(^|/)pnpm(\\.cjs)?([[:space:]]|$)"]
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

    private static func pathsEqual(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: [.caseInsensitive, .literal]) == .orderedSame
    }
}
