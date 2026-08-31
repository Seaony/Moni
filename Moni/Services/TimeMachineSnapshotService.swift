import Darwin
import Foundation

nonisolated enum TimeMachineSnapshotState: Sendable {
    case ready
    case none
    case busy
    case notConfigured
    case unavailable
    case failed
}

nonisolated struct TimeMachineSnapshotReport: Sendable {
    let state: TimeMachineSnapshotState
    let snapshotCount: Int
    let incompleteBackups: [TimeMachineIncompleteBackupItem]
    let unreadableItemCount: Int
}

nonisolated struct TimeMachineIncompleteBackupItem: Identifiable, Sendable {
    let path: String
    let name: String
    let sizeBytes: UInt64
    let modifiedDate: Date
    let deviceID: UInt64
    let fileID: UInt64

    var id: String { path }
}

nonisolated enum TimeMachineSnapshotService {
    private struct CommandOutput: Sendable {
        let status: Int32
        let output: String
        let timedOut: Bool
    }

    private static let timeMachineExecutable = "/usr/bin/tmutil"
    private static let defaultsExecutable = "/usr/bin/defaults"
    private static let diskUsageExecutable = "/usr/bin/du"
    private static let minimumIncompleteBackupAge: TimeInterval = 48 * 60 * 60
    private static let incompleteBackupScanTimeout: TimeInterval = 60
    private static let incompleteBackupSizeTimeout: TimeInterval = 30

    static func scan() async -> TimeMachineSnapshotReport {
        await Task.detached(priority: .utility) {
            scanSynchronously()
        }.value
    }

    private static func scanSynchronously() -> TimeMachineSnapshotReport {
        guard FileManager.default.isExecutableFile(atPath: timeMachineExecutable),
              FileManager.default.isExecutableFile(atPath: defaultsExecutable) else {
            return emptyReport(state: .unavailable)
        }

        let configuration = run(
            defaultsExecutable,
            arguments: ["read", "/Library/Preferences/com.apple.TimeMachine", "AutoBackup"],
            timeout: 5
        )
        let configurationValue = configuration.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !configuration.timedOut,
              configuration.status == 0,
              configurationValue == "0" || configurationValue == "1" else {
            return emptyReport(state: .notConfigured)
        }

        let destinations = run(timeMachineExecutable, arguments: ["destinationinfo"], timeout: 8)
        if destinations.output.localizedCaseInsensitiveContains("No destinations configured") {
            return emptyReport(state: .notConfigured)
        }
        guard !destinations.timedOut, destinations.status == 0 else {
            return emptyReport(state: .failed)
        }

        let status = run(timeMachineExecutable, arguments: ["status"], timeout: 8)
        guard !status.timedOut, status.status == 0 else {
            return emptyReport(state: .failed)
        }
        guard status.output.range(
            of: #"(?:^|\s)"?Running"?\s*=\s*[01](?:\s*;|$)"#,
            options: .regularExpression
        ) != nil else {
            return emptyReport(state: .failed)
        }
        if status.output.range(
            of: #"(?:^|\s)"?Running"?\s*=\s*1(?:\s*;|$)"#,
            options: .regularExpression
        ) != nil {
            return emptyReport(state: .busy)
        }

        let snapshots = run(
            timeMachineExecutable,
            arguments: ["listlocalsnapshots", "/"],
            timeout: 10
        )
        guard !snapshots.timedOut, snapshots.status == 0 else {
            return emptyReport(state: .failed)
        }
        let pattern = #"com\.apple\.TimeMachine\.\d{4}-\d{2}-\d{2}-\d{6}"#
        let expression = try? NSRegularExpression(pattern: pattern)
        let range = NSRange(snapshots.output.startIndex..., in: snapshots.output)
        let count = expression?.matches(in: snapshots.output, range: range).count ?? 0
        let incompleteBackups = scanIncompleteBackups(referenceDate: Date())
        return TimeMachineSnapshotReport(
            state: count > 0 || !incompleteBackups.items.isEmpty ? .ready : .none,
            snapshotCount: count,
            incompleteBackups: incompleteBackups.items,
            unreadableItemCount: incompleteBackups.unreadableItemCount
        )
    }

    private static func emptyReport(state: TimeMachineSnapshotState) -> TimeMachineSnapshotReport {
        TimeMachineSnapshotReport(
            state: state,
            snapshotCount: 0,
            incompleteBackups: [],
            unreadableItemCount: 0
        )
    }

    private static func scanIncompleteBackups(referenceDate: Date) -> (
        items: [TimeMachineIncompleteBackupItem],
        unreadableItemCount: Int
    ) {
        let deadline = ProcessInfo.processInfo.systemUptime + incompleteBackupScanTimeout
        var items: [TimeMachineIncompleteBackupItem] = []
        var unreadableItemCount = 0
        for volume in localBackupVolumes() {
            guard !Task.isCancelled else { return ([], 0) }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                return (items, unreadableItemCount + 1)
            }
            let root = volume.appendingPathComponent("Backups.backupdb", isDirectory: true)
            guard let rootIdentity = directoryIdentity(at: root) else { continue }
            let result = scanIncompleteBackups(
                at: root,
                rootDeviceID: rootIdentity.deviceID,
                referenceDate: referenceDate,
                deadline: deadline
            )
            if result.completed {
                items.append(contentsOf: result.items)
            } else {
                unreadableItemCount += 1
            }
        }
        return (
            items.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending },
            unreadableItemCount
        )
    }

    private static func scanIncompleteBackups(
        at root: URL,
        rootDeviceID: UInt64,
        referenceDate: Date,
        deadline: TimeInterval
    ) -> (
        items: [TimeMachineIncompleteBackupItem],
        completed: Bool
    ) {
        var encounteredError = false
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { _, _ in
                encounteredError = true
                return false
            }
        ) else {
            return ([], false)
        }

        let rootDepth = root.pathComponents.count
        var items: [TimeMachineIncompleteBackupItem] = []
        while let url = enumerator.nextObject() as? URL {
            guard !Task.isCancelled,
                  ProcessInfo.processInfo.systemUptime < deadline else {
                return ([], false)
            }
            let depth = url.pathComponents.count - rootDepth
            if depth > 3 {
                enumerator.skipDescendants()
                continue
            }
            guard let identity = directoryIdentity(at: url) else { continue }
            guard identity.deviceID == rootDeviceID else {
                enumerator.skipDescendants()
                continue
            }
            let name = url.lastPathComponent.lowercased()
            guard name.hasSuffix(".inprogress"),
                  referenceDate.timeIntervalSince(identity.modifiedDate) >= minimumIncompleteBackupAge,
                  !CleanupPreferences.isWhitelisted(url.path) else {
                continue
            }
            enumerator.skipDescendants()
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0,
                  let size = allocatedSize(
                      at: url.path,
                      timeout: min(incompleteBackupSizeTimeout, remaining)
                  ),
                  size > 0,
                  candidateIsStillEligible(
                      at: url,
                      expected: identity,
                      referenceDate: referenceDate
                  ) else {
                continue
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                return ([], false)
            }
            items.append(TimeMachineIncompleteBackupItem(
                path: url.standardizedFileURL.path,
                name: url.lastPathComponent,
                sizeBytes: size,
                modifiedDate: identity.modifiedDate,
                deviceID: identity.deviceID,
                fileID: identity.fileID
            ))
        }
        return (encounteredError ? [] : items, !encounteredError)
    }

    private static func localBackupVolumes() -> [URL] {
        let keys: Set<URLResourceKey> = [
            .volumeIsInternalKey, .volumeIsLocalKey, .volumeIsReadOnlyKey
        ]
        return (FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(keys),
            options: [.skipHiddenVolumes]
        ) ?? []).compactMap { volume in
            let standardized = volume.standardizedFileURL
            guard pathsEqual(standardized.deletingLastPathComponent().path, "/Volumes"),
                  let values = try? standardized.resourceValues(forKeys: keys),
                  values.volumeIsInternal == false,
                  values.volumeIsLocal == true,
                  values.volumeIsReadOnly == false,
                  directoryIdentity(at: standardized) != nil else {
                return nil
            }
            return standardized
        }
    }

    private static func candidateIsStillEligible(
        at url: URL,
        expected: (deviceID: UInt64, fileID: UInt64, modifiedDate: Date),
        referenceDate: Date
    ) -> Bool {
        guard timeMachineIsIdle(),
              let current = directoryIdentity(at: url),
              current.deviceID == expected.deviceID,
              current.fileID == expected.fileID,
              current.modifiedDate == expected.modifiedDate,
              referenceDate.timeIntervalSince(current.modifiedDate) >= minimumIncompleteBackupAge,
              !CleanupPreferences.isWhitelisted(url.path),
              timeMachineIsIdle(),
              let final = directoryIdentity(at: url),
              final.deviceID == expected.deviceID,
              final.fileID == expected.fileID,
              final.modifiedDate == expected.modifiedDate else {
            return false
        }
        return true
    }

    private static func timeMachineIsIdle() -> Bool {
        let status = run(timeMachineExecutable, arguments: ["status"], timeout: 8)
        guard !status.timedOut,
              status.status == 0,
              status.output.range(
                  of: #"(?:^|\s)"?Running"?\s*=\s*[01](?:\s*;|$)"#,
                  options: .regularExpression
              ) != nil else {
            return false
        }
        return status.output.range(
            of: #"(?:^|\s)"?Running"?\s*=\s*1(?:\s*;|$)"#,
            options: .regularExpression
        ) == nil
    }

    private static func directoryIdentity(at url: URL) -> (
        deviceID: UInt64,
        fileID: UInt64,
        modifiedDate: Date
    )? {
        var value = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &value)
        }
        guard result == 0, value.st_mode & S_IFMT == S_IFDIR else { return nil }
        return (
            UInt64(value.st_dev),
            UInt64(value.st_ino),
            Date(timeIntervalSince1970: TimeInterval(value.st_mtimespec.tv_sec))
        )
    }

    private static func allocatedSize(at path: String, timeout: TimeInterval) -> UInt64? {
        guard FileManager.default.isExecutableFile(atPath: diskUsageExecutable) else { return nil }
        let result = run(diskUsageExecutable, arguments: ["-sk", path], timeout: timeout)
        guard !result.timedOut,
              result.status == 0,
              let kilobytesText = result.output.split(whereSeparator: \.isWhitespace).first,
              let kilobytes = UInt64(kilobytesText) else {
            return nil
        }
        let (bytes, overflow) = kilobytes.multipliedReportingOverflow(by: 1024)
        return overflow ? nil : bytes
    }

    private static func pathsEqual(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: [.caseInsensitive, .literal]) == .orderedSame
    }

    private static func run(
        _ executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) -> CommandOutput {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        process.environment = environment
        do {
            try process.run()
        } catch {
            return CommandOutput(status: -1, output: error.localizedDescription, timedOut: false)
        }

        let timeoutWork = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let timedOut = !timeoutWork.isCancelled && process.terminationReason == .uncaughtSignal
        timeoutWork.cancel()
        return CommandOutput(
            status: process.terminationStatus,
            output: String(decoding: data, as: UTF8.self),
            timedOut: timedOut
        )
    }
}
