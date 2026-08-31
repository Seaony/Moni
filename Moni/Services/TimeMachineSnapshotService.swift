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

nonisolated struct TimeMachineBackupCleanupPlan: Identifiable, Sendable {
    let cleanupPlan: CleanupPlan
    let items: [TimeMachineIncompleteBackupItem]

    var id: UUID { cleanupPlan.id }
}

nonisolated struct TimeMachineBackupCleanupResult: Sendable {
    let removedPaths: [String]
    let rejectedItems: [CleanupRejectedItem]
    let failedPaths: [String]
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
    private static let cleanupPlanLifetime: TimeInterval = 5 * 60

    static func scan() async -> TimeMachineSnapshotReport {
        await Task.detached(priority: .utility) {
            scanSynchronously()
        }.value
    }

    static func previewCleanup(
        items: [TimeMachineIncompleteBackupItem]
    ) async -> TimeMachineBackupCleanupPlan {
        let plan = await CleanupService.shared.preview(
            paths: items.map(\.path),
            scope: .maintenance
        )
        return TimeMachineBackupCleanupPlan(cleanupPlan: plan, items: items)
    }

    static func executeCleanup(
        _ plan: TimeMachineBackupCleanupPlan
    ) async -> TimeMachineBackupCleanupResult {
        let result = await Task.detached(priority: .userInitiated) {
            executeCleanupSynchronously(plan)
        }.value
        let previewRejectedPaths = Set(plan.cleanupPlan.rejectedItems.map(\.path))
        await CleanupService.shared.recordDeletionResult(
            removedPaths: result.removedPaths,
            rejectedItems: result.rejectedItems.filter {
                !previewRejectedPaths.contains($0.path)
            },
            failedPaths: result.failedPaths,
            scope: .maintenance
        )
        return result
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

    private static func executeCleanupSynchronously(
        _ plan: TimeMachineBackupCleanupPlan
    ) -> TimeMachineBackupCleanupResult {
        guard plan.cleanupPlan.scope == .maintenance else {
            return TimeMachineBackupCleanupResult(
                removedPaths: [],
                rejectedItems: plan.cleanupPlan.rejectedItems + plan.cleanupPlan.candidates.map {
                    CleanupRejectedItem(path: $0.path, reason: .protected)
                },
                failedPaths: []
            )
        }
        guard Date().timeIntervalSince(plan.cleanupPlan.createdAt) <= cleanupPlanLifetime else {
            return TimeMachineBackupCleanupResult(
                removedPaths: [],
                rejectedItems: plan.cleanupPlan.rejectedItems + plan.cleanupPlan.candidates.map {
                    CleanupRejectedItem(path: $0.path, reason: .expired)
                },
                failedPaths: []
            )
        }

        let itemsByPath = Dictionary(uniqueKeysWithValues: plan.items.map { ($0.path, $0) })
        let referenceDate = Date()
        var eligible: [(candidate: CleanupCandidate, item: TimeMachineIncompleteBackupItem)] = []
        var rejectedItems = plan.cleanupPlan.rejectedItems
        for candidate in plan.cleanupPlan.candidates {
            guard let item = itemsByPath[candidate.path],
                  candidate.device == item.deviceID,
                  candidate.inode == item.fileID,
                  candidateIsStillEligible(
                      at: URL(fileURLWithPath: candidate.path),
                      expected: (
                          deviceID: item.deviceID,
                          fileID: item.fileID,
                          modifiedDate: item.modifiedDate
                      ),
                      referenceDate: referenceDate
                  ) else {
                rejectedItems.append(CleanupRejectedItem(path: candidate.path, reason: .changed))
                continue
            }
            eligible.append((candidate, item))
        }
        guard !eligible.isEmpty else {
            return TimeMachineBackupCleanupResult(
                removedPaths: [],
                rejectedItems: rejectedItems,
                failedPaths: []
            )
        }

        var arguments = ["-e", privilegedDeleteScript]
        for entry in eligible {
            arguments.append(entry.candidate.path)
            arguments.append(
                "\(entry.item.deviceID):\(entry.item.fileID):\(Int64(entry.item.modifiedDate.timeIntervalSince1970))"
            )
        }
        let execution = run("/usr/bin/osascript", arguments: arguments, timeout: 300)
        let removedIndexes = Set(execution.output.split(whereSeparator: \.isNewline).compactMap { line -> Int? in
            guard line.hasPrefix("REMOVED:"),
                  let index = Int(line.dropFirst("REMOVED:".count)) else {
                return nil
            }
            return index
        })
        var removedPaths: [String] = []
        var failedPaths: [String] = []
        for (offset, entry) in eligible.enumerated() {
            if removedIndexes.contains(offset + 1), !pathExists(at: entry.candidate.path) {
                removedPaths.append(entry.candidate.path)
            } else {
                failedPaths.append(entry.candidate.path)
            }
        }
        return TimeMachineBackupCleanupResult(
            removedPaths: removedPaths,
            rejectedItems: rejectedItems,
            failedPaths: failedPaths
        )
    }

    private static func pathExists(at path: String) -> Bool {
        var value = stat()
        return path.withCString { lstat($0, &value) } == 0
    }

    private static let privilegedDeleteScript = #"""
    on run argv
        set commandText to "tm_idle() { status=$(/usr/bin/tmutil status 2>/dev/null) || return 1; printf '%s\\n' \"$status\" | /usr/bin/grep -Eq '(^|[[:space:]])(\"Running\"|Running)[[:space:]]*=' || return 1; printf '%s\\n' \"$status\" | /usr/bin/grep -Eq '(^|[[:space:]])(\"Running\"|Running)[[:space:]]*=[[:space:]]*1([[:space:]]*;|$)' && return 1; return 0; }; "
        set commandText to commandText & "tm_candidate_path() { case \"$1\" in /Volumes/*/Backups.backupdb/*) return 0 ;; *) return 1 ;; esac; }; "
        set argumentCount to count of argv
        set candidateIndex to 0
        repeat with argumentIndex from 1 to argumentCount by 2
            set candidateIndex to candidateIndex + 1
            set sourcePath to item argumentIndex of argv
            set expectedIdentity to item (argumentIndex + 1) of argv
            set commandText to commandText & "( source_path=" & quoted form of sourcePath & "; expected_identity=" & quoted form of expectedIdentity & "; "
            set commandText to commandText & "tm_candidate_path \"$source_path\" && [ -d \"$source_path\" ] && [ ! -L \"$source_path\" ] && "
            set commandText to commandText & "case \"${source_path##*/}\" in *.inProgress|*.inprogress) true ;; *) false ;; esac && "
            set commandText to commandText & "tm_idle && current_identity=$(/usr/bin/stat -f '%d:%i:%m' \"$source_path\") && [ \"$current_identity\" = \"$expected_identity\" ] && "
            set commandText to commandText & "mtime=${current_identity##*:} && now=$(/bin/date +%s) && [ \"$now\" -ge \"$mtime\" ] && [ $((now - mtime)) -ge 172800 ] && "
            set commandText to commandText & "tm_idle && final_identity=$(/usr/bin/stat -f '%d:%i:%m' \"$source_path\") && [ \"$final_identity\" = \"$expected_identity\" ] && "
            set commandText to commandText & "/usr/bin/tmutil delete \"$source_path\" ) && printf 'REMOVED:%s\\n' " & candidateIndex & " || printf 'FAILED:%s\\n' " & candidateIndex & "; "
        end repeat
        do shell script commandText with administrator privileges
    end run
    """#

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
