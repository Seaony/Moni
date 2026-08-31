import Darwin
import Foundation

nonisolated enum NotificationMaintenanceState: Sendable {
    case ready
    case healthy
    case protected
    case unavailable
    case failed
}

nonisolated struct NotificationMaintenanceSnapshot: Sendable {
    let path: String
    let sizeBytes: UInt64
    let state: NotificationMaintenanceState
    let device: UInt64
    let inode: UInt64
}

nonisolated struct NotificationMaintenanceResult: Sendable {
    let cleaned: Bool
    let skipped: Bool
    let failed: Bool
}

nonisolated enum NotificationMaintenanceService {
    private struct CommandOutput: Sendable {
        let status: Int32
        let output: String
    }

    private static let sqliteExecutable = "/usr/bin/sqlite3"
    private static let getconfExecutable = "/usr/bin/getconf"
    private static let killallExecutable = "/usr/bin/killall"
    private static let minimumDatabaseSize: UInt64 = 50 * 1024 * 1024

    static func scan() async -> NotificationMaintenanceSnapshot {
        await Task.detached(priority: .utility) {
            scanSynchronously()
        }.value
    }

    static func clean(_ planned: NotificationMaintenanceSnapshot) async -> NotificationMaintenanceResult {
        await Task.detached(priority: .utility) {
            guard planned.state == .ready,
                  FileManager.default.isExecutableFile(atPath: sqliteExecutable),
                  let currentPath = databasePath(),
                  currentPath == planned.path,
                  !CleanupPreferences.isWhitelisted(currentPath),
                  let identity = fileIdentity(currentPath),
                  identity.device == planned.device,
                  identity.inode == planned.inode else {
                return NotificationMaintenanceResult(cleaned: false, skipped: true, failed: false)
            }
            let current = scanSynchronously()
            guard current.state == .ready,
                  current.path == planned.path,
                  current.device == planned.device,
                  current.inode == planned.inode else {
                return NotificationMaintenanceResult(cleaned: false, skipped: true, failed: false)
            }

            let result = run(
                sqliteExecutable,
                arguments: [
                    current.path,
                    "DELETE FROM record WHERE delivered_date < strftime('%s','now','-30 days'); VACUUM;"
                ],
                timeout: 40
            )
            guard result.status == 0 else {
                return NotificationMaintenanceResult(cleaned: false, skipped: false, failed: true)
            }
            if FileManager.default.isExecutableFile(atPath: killallExecutable) {
                _ = run(killallExecutable, arguments: ["NotificationCenter"], timeout: 5)
            }
            return NotificationMaintenanceResult(cleaned: true, skipped: false, failed: false)
        }.value
    }

    private static func scanSynchronously() -> NotificationMaintenanceSnapshot {
        guard FileManager.default.isExecutableFile(atPath: sqliteExecutable),
              let path = databasePath() else {
            return emptySnapshot(state: .unavailable)
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard isRegularNonSymlink(url), let identity = fileIdentity(path) else {
            return NotificationMaintenanceSnapshot(
                path: path,
                sizeBytes: 0,
                state: .failed,
                device: 0,
                inode: 0
            )
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt64.init) ?? 0
        if CleanupPreferences.isWhitelisted(path) {
            return snapshot(path, size, .protected, identity)
        }
        guard isSQLiteDatabase(url) else {
            return snapshot(path, size, .failed, identity)
        }
        return snapshot(
            path,
            size,
            size >= minimumDatabaseSize ? .ready : .healthy,
            identity
        )
    }

    private static func databasePath() -> String? {
        let fileManager = FileManager.default
        let groupPath = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.com.apple.usernoted/db2/db")
            .standardizedFileURL.path
        if fileManager.fileExists(atPath: groupPath) { return groupPath }

        guard FileManager.default.isExecutableFile(atPath: getconfExecutable) else { return nil }
        let result = run(getconfExecutable, arguments: ["DARWIN_USER_DIR"], timeout: 5)
        guard result.status == 0 else { return nil }
        let userDirectory = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userDirectory.isEmpty else { return nil }
        let legacyPath = URL(fileURLWithPath: userDirectory, isDirectory: true)
            .appendingPathComponent("com.apple.notificationcenter/db2/db")
            .standardizedFileURL.path
        return fileManager.fileExists(atPath: legacyPath) ? legacyPath : nil
    }

    private static func snapshot(
        _ path: String,
        _ sizeBytes: UInt64,
        _ state: NotificationMaintenanceState,
        _ identity: (device: UInt64, inode: UInt64)
    ) -> NotificationMaintenanceSnapshot {
        NotificationMaintenanceSnapshot(
            path: path,
            sizeBytes: sizeBytes,
            state: state,
            device: identity.device,
            inode: identity.inode
        )
    }

    private static func emptySnapshot(
        state: NotificationMaintenanceState
    ) -> NotificationMaintenanceSnapshot {
        NotificationMaintenanceSnapshot(
            path: "",
            sizeBytes: 0,
            state: state,
            device: 0,
            inode: 0
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
