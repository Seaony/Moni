import Darwin
import Foundation

nonisolated enum CoreDuetMaintenanceState: Sendable {
    case ready
    case healthy
    case protected
    case unavailable
    case failed
}

nonisolated struct CoreDuetMaintenanceFile: Identifiable, Sendable {
    let path: String
    let sizeBytes: UInt64
    let device: UInt64
    let inode: UInt64

    var id: String { path }
}

nonisolated struct CoreDuetMaintenanceSnapshot: Sendable {
    let databasePath: String
    let totalSizeBytes: UInt64
    let state: CoreDuetMaintenanceState
    let files: [CoreDuetMaintenanceFile]
}

nonisolated struct CoreDuetMaintenanceResult: Sendable {
    let databaseCleaned: Bool
    let trashedSidecarCount: Int
    let failedSidecarCount: Int
    let skipped: Bool
    let databaseFailed: Bool
}

nonisolated enum CoreDuetMaintenanceService {
    private struct CommandOutput: Sendable {
        let status: Int32
        let output: String
    }

    private static let sqliteExecutable = "/usr/bin/sqlite3"
    private static let minimumCombinedSize: UInt64 = 100 * 1024 * 1024

    static func scan() async -> CoreDuetMaintenanceSnapshot {
        await Task.detached(priority: .utility) {
            scanSynchronously()
        }.value
    }

    static func clean(_ planned: CoreDuetMaintenanceSnapshot) async -> CoreDuetMaintenanceResult {
        await Task.detached(priority: .utility) {
            guard planned.state == .ready,
                  FileManager.default.isExecutableFile(atPath: sqliteExecutable) else {
                return skippedResult()
            }
            let current = scanSynchronously()
            guard current.state == .ready,
                  current.databasePath == planned.databasePath,
                  sameFiles(current.files, planned.files) else {
                return skippedResult()
            }

            let sidecars = current.files.filter { $0.path != current.databasePath }
            var trashedSidecarCount = 0
            var failedSidecarCount = 0
            for file in sidecars {
                guard matchesIdentity(file),
                      !CleanupPreferences.isWhitelisted(file.path) else {
                    failedSidecarCount += 1
                    continue
                }
                do {
                    var resultingURL: NSURL?
                    try FileManager.default.trashItem(
                        at: URL(fileURLWithPath: file.path),
                        resultingItemURL: &resultingURL
                    )
                    trashedSidecarCount += 1
                } catch {
                    failedSidecarCount += 1
                }
            }

            guard let database = current.files.first(where: { $0.path == current.databasePath }),
                  matchesIdentity(database),
                  !CleanupPreferences.isWhitelisted(database.path) else {
                return CoreDuetMaintenanceResult(
                    databaseCleaned: false,
                    trashedSidecarCount: trashedSidecarCount,
                    failedSidecarCount: failedSidecarCount,
                    skipped: true,
                    databaseFailed: false
                )
            }
            let result = run(
                sqliteExecutable,
                arguments: [
                    database.path,
                    "DELETE FROM ZOBJECT WHERE ZCREATIONDATE < (strftime('%s','now','-90 days') - strftime('%s','2001-01-01')); VACUUM;"
                ],
                timeout: 45
            )
            return CoreDuetMaintenanceResult(
                databaseCleaned: result.status == 0,
                trashedSidecarCount: trashedSidecarCount,
                failedSidecarCount: failedSidecarCount,
                skipped: false,
                databaseFailed: result.status != 0
            )
        }.value
    }

    private static func scanSynchronously() -> CoreDuetMaintenanceSnapshot {
        let fileManager = FileManager.default
        let databasePath = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Knowledge/knowledgeC.db")
            .standardizedFileURL.path
        guard fileManager.fileExists(atPath: databasePath) else {
            return CoreDuetMaintenanceSnapshot(
                databasePath: databasePath,
                totalSizeBytes: 0,
                state: .unavailable,
                files: []
            )
        }
        guard FileManager.default.isExecutableFile(atPath: sqliteExecutable) else {
            return CoreDuetMaintenanceSnapshot(
                databasePath: databasePath,
                totalSizeBytes: 0,
                state: .unavailable,
                files: []
            )
        }

        let paths = [databasePath, databasePath + "-wal", databasePath + "-shm"]
            .filter(fileManager.fileExists(atPath:))
        var files: [CoreDuetMaintenanceFile] = []
        for path in paths {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard isRegularNonSymlink(url),
                  let identity = fileIdentity(path),
                  let size = allocatedSize(url) else {
                return CoreDuetMaintenanceSnapshot(
                    databasePath: databasePath,
                    totalSizeBytes: 0,
                    state: .failed,
                    files: []
                )
            }
            files.append(CoreDuetMaintenanceFile(
                path: path,
                sizeBytes: size,
                device: identity.device,
                inode: identity.inode
            ))
        }
        guard let databaseURL = files.first(where: { $0.path == databasePath }).map({ URL(fileURLWithPath: $0.path) }),
              isSQLiteDatabase(databaseURL) else {
            return CoreDuetMaintenanceSnapshot(
                databasePath: databasePath,
                totalSizeBytes: 0,
                state: .failed,
                files: files
            )
        }
        let total = files.reduce(UInt64(0)) { partial, file in
            let sum = partial.addingReportingOverflow(file.sizeBytes)
            return sum.overflow ? UInt64.max : sum.partialValue
        }
        let state: CoreDuetMaintenanceState
        if files.contains(where: { CleanupPreferences.isWhitelisted($0.path) }) {
            state = .protected
        } else {
            state = total >= minimumCombinedSize ? .ready : .healthy
        }
        return CoreDuetMaintenanceSnapshot(
            databasePath: databasePath,
            totalSizeBytes: total,
            state: state,
            files: files
        )
    }

    private static func allocatedSize(_ url: URL) -> UInt64? {
        guard let values = try? url.resourceValues(forKeys: [
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
            .fileSizeKey
        ]) else { return nil }
        let value = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize
        return value.map(UInt64.init)
    }

    private static func sameFiles(
        _ current: [CoreDuetMaintenanceFile],
        _ planned: [CoreDuetMaintenanceFile]
    ) -> Bool {
        guard current.count == planned.count else { return false }
        let plannedByPath = Dictionary(uniqueKeysWithValues: planned.map { ($0.path, $0) })
        return current.allSatisfy { file in
            guard let expected = plannedByPath[file.path] else { return false }
            return file.device == expected.device && file.inode == expected.inode
        }
    }

    private static func skippedResult() -> CoreDuetMaintenanceResult {
        CoreDuetMaintenanceResult(
            databaseCleaned: false,
            trashedSidecarCount: 0,
            failedSidecarCount: 0,
            skipped: true,
            databaseFailed: false
        )
    }

    private static func isSQLiteDatabase(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 16) else { return false }
        return header == Data("SQLite format 3\0".utf8)
    }

    private static func isRegularNonSymlink(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private static func fileIdentity(_ path: String) -> (device: UInt64, inode: UInt64)? {
        var value = stat()
        let result = path.withCString { lstat($0, &value) }
        guard result == 0 else { return nil }
        return (UInt64(value.st_dev), UInt64(value.st_ino))
    }

    private static func matchesIdentity(_ file: CoreDuetMaintenanceFile) -> Bool {
        guard let identity = fileIdentity(file.path) else { return false }
        return identity.device == file.device && identity.inode == file.inode
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
