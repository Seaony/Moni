import Foundation

nonisolated enum MaintenanceProbeState: Sendable {
    case ready
    case unavailable
    case protected
    case failed
}

nonisolated struct QuarantineMaintenanceSnapshot: Sendable {
    let databasePath: String
    let entryCount: Int
    let state: MaintenanceProbeState
}

nonisolated struct QuarantineCleanupResult: Sendable {
    let removedCount: Int
    let state: MaintenanceProbeState
}

nonisolated enum DiskVerificationOutcome: Sendable {
    case healthy
    case attention
    case failed
    case unavailable
}

nonisolated struct DiskVerificationResult: Sendable {
    let outcome: DiskVerificationOutcome
    let detail: String
}

nonisolated enum MaintenanceDiagnosticsService {
    private struct CommandOutput: Sendable {
        let status: Int32
        let output: String
    }

    private static let sqliteExecutable = "/usr/bin/sqlite3"
    private static let diskutilExecutable = "/usr/sbin/diskutil"

    static var diskVerificationIsAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: diskutilExecutable)
    }

    static func scanQuarantineHistory() async -> QuarantineMaintenanceSnapshot {
        await Task.detached(priority: .utility) {
            quarantineSnapshot()
        }.value
    }

    static func clearQuarantineHistory() async -> QuarantineCleanupResult {
        await Task.detached(priority: .utility) {
            let snapshot = quarantineSnapshot()
            guard snapshot.state == .ready else {
                return QuarantineCleanupResult(removedCount: 0, state: snapshot.state)
            }
            guard snapshot.entryCount > 0 else {
                return QuarantineCleanupResult(removedCount: 0, state: .ready)
            }

            let result = runWithOutput(
                sqliteExecutable,
                arguments: [
                    snapshot.databasePath,
                    "DELETE FROM LSQuarantineEvent; VACUUM;"
                ],
                timeout: 30
            )
            guard result.status == 0 else {
                return QuarantineCleanupResult(removedCount: 0, state: .failed)
            }
            let verification = quarantineSnapshot()
            guard verification.state == .ready, verification.entryCount == 0 else {
                return QuarantineCleanupResult(removedCount: 0, state: .failed)
            }
            return QuarantineCleanupResult(removedCount: snapshot.entryCount, state: .ready)
        }.value
    }

    static func verifyStartupVolume() async -> DiskVerificationResult {
        await Task.detached(priority: .utility) {
            guard FileManager.default.isExecutableFile(atPath: diskutilExecutable) else {
                return DiskVerificationResult(outcome: .unavailable, detail: "")
            }
            let result = runWithOutput(
                diskutilExecutable,
                arguments: ["verifyVolume", "/"],
                timeout: 180
            )
            let normalized = result.output.lowercased()
            if result.status != 0 {
                return DiskVerificationResult(outcome: .failed, detail: result.output)
            }
            if normalized.contains("appears to be ok") {
                return DiskVerificationResult(outcome: .healthy, detail: result.output)
            }
            if normalized.contains("error")
                || normalized.contains("corrupt")
                || normalized.contains("invalid") {
                return DiskVerificationResult(outcome: .attention, detail: result.output)
            }
            return DiskVerificationResult(outcome: .failed, detail: result.output)
        }.value
    }

    private static func quarantineSnapshot() -> QuarantineMaintenanceSnapshot {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let path = home + "/Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2"
        guard FileManager.default.isExecutableFile(atPath: sqliteExecutable) else {
            return QuarantineMaintenanceSnapshot(databasePath: path, entryCount: 0, state: .unavailable)
        }
        guard FileManager.default.fileExists(atPath: path) else {
            return QuarantineMaintenanceSnapshot(databasePath: path, entryCount: 0, state: .ready)
        }
        guard !CleanupPreferences.isWhitelisted(path) else {
            return QuarantineMaintenanceSnapshot(databasePath: path, entryCount: 0, state: .protected)
        }

        let result = runWithOutput(
            sqliteExecutable,
            arguments: [path, "SELECT COUNT(*) FROM LSQuarantineEvent;"],
            timeout: 8
        )
        let value = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.status == 0, let entryCount = Int(value), entryCount >= 0 else {
            return QuarantineMaintenanceSnapshot(databasePath: path, entryCount: 0, state: .failed)
        }
        return QuarantineMaintenanceSnapshot(databasePath: path, entryCount: entryCount, state: .ready)
    }

    private static func runWithOutput(
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
            return CommandOutput(status: -1, output: error.localizedDescription)
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
            output: String(decoding: data, as: UTF8.self)
        )
    }
}
