import Darwin
import Foundation

nonisolated enum DatabaseMaintenanceState: Sendable {
    case ready
    case optimal
    case oversized
    case protected
    case failed
}

nonisolated struct DatabaseMaintenanceItem: Identifiable, Sendable {
    let path: String
    let applicationName: String
    let sizeBytes: UInt64
    let reclaimableBytes: UInt64
    let state: DatabaseMaintenanceState
    let device: UInt64
    let inode: UInt64

    var id: String { path }
}

nonisolated enum DatabaseMaintenanceAvailability: Sendable {
    case ready
    case unavailable
    case processProbeFailed
}

nonisolated struct DatabaseMaintenanceSnapshot: Sendable {
    let availability: DatabaseMaintenanceAvailability
    let busyApplications: [String]
    let items: [DatabaseMaintenanceItem]
}

nonisolated struct DatabaseMaintenanceResult: Sendable {
    let optimizedCount: Int
    let skippedCount: Int
    let failedCount: Int
}

nonisolated enum DatabaseMaintenanceService {
    private struct CommandOutput: Sendable {
        let status: Int32
        let output: String
    }

    private static let sqliteExecutable = "/usr/bin/sqlite3"
    private static let processProbeExecutable = "/usr/bin/pgrep"
    private static let maximumDatabaseSize: UInt64 = 100 * 1024 * 1024
    private static let applicationNames = ["Mail", "Safari", "Messages"]

    static func scan() async -> DatabaseMaintenanceSnapshot {
        await Task.detached(priority: .utility) {
            guard FileManager.default.isExecutableFile(atPath: sqliteExecutable),
                  FileManager.default.isExecutableFile(atPath: processProbeExecutable) else {
                return DatabaseMaintenanceSnapshot(
                    availability: .unavailable,
                    busyApplications: [],
                    items: []
                )
            }

            let processState = runningApplications()
            guard !processState.probeFailed else {
                return DatabaseMaintenanceSnapshot(
                    availability: .processProbeFailed,
                    busyApplications: [],
                    items: []
                )
            }
            guard processState.names.isEmpty else {
                return DatabaseMaintenanceSnapshot(
                    availability: .ready,
                    busyApplications: processState.names,
                    items: []
                )
            }

            let items = databasePaths().compactMap { candidate in
                inspectDatabase(path: candidate.path, applicationName: candidate.applicationName)
            }
            return DatabaseMaintenanceSnapshot(
                availability: .ready,
                busyApplications: [],
                items: items.sorted { lhs, rhs in
                    if lhs.applicationName != rhs.applicationName {
                        return lhs.applicationName.localizedStandardCompare(rhs.applicationName) == .orderedAscending
                    }
                    return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
                }
            )
        }.value
    }

    static func optimize(_ items: [DatabaseMaintenanceItem]) async -> DatabaseMaintenanceResult {
        await Task.detached(priority: .utility) {
            guard FileManager.default.isExecutableFile(atPath: sqliteExecutable),
                  FileManager.default.isExecutableFile(atPath: processProbeExecutable) else {
                return DatabaseMaintenanceResult(optimizedCount: 0, skippedCount: 0, failedCount: items.count)
            }
            let processState = runningApplications()
            guard !processState.probeFailed, processState.names.isEmpty else {
                return DatabaseMaintenanceResult(optimizedCount: 0, skippedCount: items.count, failedCount: 0)
            }

            var optimizedCount = 0
            var skippedCount = 0
            var failedCount = 0
            for plannedItem in items {
                guard plannedItem.state == .ready,
                      matchesIdentity(plannedItem),
                      !CleanupPreferences.isWhitelisted(plannedItem.path),
                      let currentItem = inspectDatabase(
                        path: plannedItem.path,
                        applicationName: plannedItem.applicationName
                      ),
                      currentItem.state == .ready,
                      currentItem.device == plannedItem.device,
                      currentItem.inode == plannedItem.inode else {
                    skippedCount += 1
                    continue
                }

                let integrity = runWithOutput(
                    sqliteExecutable,
                    arguments: [plannedItem.path, "PRAGMA integrity_check;"],
                    timeout: 20
                )
                guard integrity.status == 0,
                      integrity.output.trimmingCharacters(in: .whitespacesAndNewlines) == "ok" else {
                    failedCount += 1
                    continue
                }

                let vacuum = runWithOutput(
                    sqliteExecutable,
                    arguments: [plannedItem.path, "VACUUM;"],
                    timeout: 30
                )
                if vacuum.status == 0 {
                    optimizedCount += 1
                } else {
                    failedCount += 1
                }
            }
            return DatabaseMaintenanceResult(
                optimizedCount: optimizedCount,
                skippedCount: skippedCount,
                failedCount: failedCount
            )
        }.value
    }

    private static func runningApplications() -> (names: [String], probeFailed: Bool) {
        var names: [String] = []
        for name in applicationNames {
            let result = runWithOutput(
                processProbeExecutable,
                arguments: ["-x", name],
                timeout: 5
            )
            switch result.status {
            case 0:
                names.append(name)
            case 1:
                continue
            default:
                return ([], true)
            }
        }
        return (names, false)
    }

    private static func databasePaths() -> [(path: String, applicationName: String)] {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        var paths: [(String, String)] = []

        let mailRoot = home.appendingPathComponent("Library/Mail", isDirectory: true)
        if let versions = try? fileManager.contentsOfDirectory(
            at: mailRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) {
            for version in versions where version.lastPathComponent.hasPrefix("V") {
                let mailData = version.appendingPathComponent("MailData", isDirectory: true)
                guard let files = try? fileManager.contentsOfDirectory(
                    at: mailData,
                    includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }
                paths.append(contentsOf: files.compactMap { url in
                    guard url.lastPathComponent.hasPrefix("Envelope Index"),
                          !url.lastPathComponent.hasSuffix("-wal"),
                          !url.lastPathComponent.hasSuffix("-shm"),
                          isRegularNonSymlink(url) else { return nil }
                    return (url.standardizedFileURL.path, "Mail")
                })
            }
        }

        let fixedPaths = [
            (home.appendingPathComponent("Library/Messages/chat.db").path, "Messages"),
            (home.appendingPathComponent("Library/Safari/History.db").path, "Safari"),
            (home.appendingPathComponent("Library/Safari/TopSites.db").path, "Safari")
        ]
        paths.append(contentsOf: fixedPaths.filter { fileManager.fileExists(atPath: $0.0) })
        return paths
    }

    private static func inspectDatabase(
        path: String,
        applicationName: String
    ) -> DatabaseMaintenanceItem? {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard isRegularNonSymlink(url), let identity = fileIdentity(path) else { return nil }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt64.init) ?? 0
        if CleanupPreferences.isWhitelisted(path) {
            return item(path, applicationName, size, 0, .protected, identity)
        }
        guard isSQLiteDatabase(url) else { return nil }
        guard size <= maximumDatabaseSize else {
            return item(path, applicationName, size, 0, .oversized, identity)
        }

        let result = runWithOutput(
            sqliteExecutable,
            arguments: [path, "PRAGMA page_count; PRAGMA freelist_count; PRAGMA page_size;"],
            timeout: 8
        )
        let values = result.output
            .split(whereSeparator: \Character.isNewline)
            .compactMap { UInt64($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard result.status == 0, values.count >= 3, values[0] > 0 else {
            return item(path, applicationName, size, 0, .failed, identity)
        }
        let pageCount = values[0]
        let freePageCount = values[1]
        let pageSize = values[2]
        let reclaimable = freePageCount.multipliedReportingOverflow(by: pageSize)
        let reclaimableBytes = reclaimable.overflow ? UInt64.max : reclaimable.partialValue
        let state: DatabaseMaintenanceState = freePageCount * 100 < pageCount * 5 ? .optimal : .ready
        return item(path, applicationName, size, reclaimableBytes, state, identity)
    }

    private static func item(
        _ path: String,
        _ applicationName: String,
        _ sizeBytes: UInt64,
        _ reclaimableBytes: UInt64,
        _ state: DatabaseMaintenanceState,
        _ identity: (device: UInt64, inode: UInt64)
    ) -> DatabaseMaintenanceItem {
        DatabaseMaintenanceItem(
            path: path,
            applicationName: applicationName,
            sizeBytes: sizeBytes,
            reclaimableBytes: reclaimableBytes,
            state: state,
            device: identity.device,
            inode: identity.inode
        )
    }

    private static func isSQLiteDatabase(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let header = try? handle.read(upToCount: 16)
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

    private static func matchesIdentity(_ item: DatabaseMaintenanceItem) -> Bool {
        guard let identity = fileIdentity(item.path) else { return false }
        return identity.device == item.device && identity.inode == item.inode
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
