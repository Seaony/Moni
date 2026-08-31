import Darwin
import Foundation

nonisolated enum SystemCleanupScanState: Sendable {
    case notScanned
    case ready
    case empty
    case unavailable
    case cancelled
    case failed
}

nonisolated enum SystemCleanupCategory: String, CaseIterable, Sendable {
    case systemCaches
    case crashReports
    case systemLogs
    case thirdPartyLogs

    var titleKey: String {
        switch self {
        case .systemCaches: "System caches"
        case .crashReports: "System crash reports"
        case .systemLogs: "System logs"
        case .thirdPartyLogs: "Third-party system logs"
        }
    }
}

nonisolated struct SystemCleanupItem: Identifiable, Sendable {
    let path: String
    let name: String
    let category: SystemCleanupCategory
    let sizeBytes: UInt64
    let modifiedDate: Date
    let deviceID: UInt64
    let fileID: UInt64

    var id: String { path }
}

nonisolated struct SystemCleanupSnapshot: Sendable {
    let state: SystemCleanupScanState
    let items: [SystemCleanupItem]
    let unreadableItemCount: Int
}

nonisolated enum SystemCleanupService {
    private struct CommandOutput: Sendable {
        let status: Int32
        let output: String
        let timedOut: Bool
    }

    private static let scriptExecutable = "/usr/bin/osascript"
    private static let minimumAge: TimeInterval = 7 * 24 * 60 * 60

    static func scan() async -> SystemCleanupSnapshot {
        await Task.detached(priority: .userInitiated) {
            scanSynchronously(referenceDate: Date())
        }.value
    }

    private static func scanSynchronously(referenceDate: Date) -> SystemCleanupSnapshot {
        guard FileManager.default.isExecutableFile(atPath: scriptExecutable) else {
            return SystemCleanupSnapshot(state: .unavailable, items: [], unreadableItemCount: 0)
        }
        let result = run(
            scriptExecutable,
            arguments: ["-e", administratorScript, scanShellScript],
            timeout: 120
        )
        if result.timedOut {
            return SystemCleanupSnapshot(state: .failed, items: [], unreadableItemCount: 0)
        }
        if result.status != 0 {
            let cancelled = result.output.localizedCaseInsensitiveContains("User canceled")
                || result.output.contains("(-128)")
            return SystemCleanupSnapshot(
                state: cancelled ? .cancelled : .failed,
                items: [],
                unreadableItemCount: 0
            )
        }

        var itemsByPath: [String: SystemCleanupItem] = [:]
        var unreadableItemCount = 0
        var scanFailed = false
        for line in result.output.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard let recordType = fields.first else { continue }
            if recordType == "UNREADABLE" {
                unreadableItemCount += 1
                continue
            }
            if recordType == "ERROR" {
                scanFailed = true
                continue
            }
            guard recordType == "ITEM",
                  fields.count == 7,
                  let category = SystemCleanupCategory(rawValue: String(fields[1])),
                  let deviceID = UInt64(fields[2]),
                  let fileID = UInt64(fields[3]),
                  let modificationSeconds = Int64(fields[4]),
                  let sizeBytes = UInt64(fields[5]),
                  let pathData = Data(base64Encoded: String(fields[6])),
                  let path = String(data: pathData, encoding: .utf8) else {
                scanFailed = true
                continue
            }
            let modifiedDate = Date(timeIntervalSince1970: TimeInterval(modificationSeconds))
            guard let item = validatedItem(
                path: path,
                category: category,
                expectedDeviceID: deviceID,
                expectedFileID: fileID,
                expectedModifiedDate: modifiedDate,
                expectedSizeBytes: sizeBytes,
                referenceDate: referenceDate
            ) else {
                continue
            }
            itemsByPath[item.path] = item
        }
        guard !scanFailed else {
            return SystemCleanupSnapshot(
                state: .failed,
                items: [],
                unreadableItemCount: unreadableItemCount
            )
        }

        let items = itemsByPath.values.sorted {
            if $0.category != $1.category {
                let lhs = SystemCleanupCategory.allCases.firstIndex(of: $0.category) ?? 0
                let rhs = SystemCleanupCategory.allCases.firstIndex(of: $1.category) ?? 0
                return lhs < rhs
            }
            if $0.sizeBytes != $1.sizeBytes { return $0.sizeBytes > $1.sizeBytes }
            return $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
        return SystemCleanupSnapshot(
            state: items.isEmpty ? .empty : .ready,
            items: items,
            unreadableItemCount: unreadableItemCount
        )
    }

    private static func validatedItem(
        path: String,
        category: SystemCleanupCategory,
        expectedDeviceID: UInt64,
        expectedFileID: UInt64,
        expectedModifiedDate: Date,
        expectedSizeBytes: UInt64,
        referenceDate: Date
    ) -> SystemCleanupItem? {
        guard path.hasPrefix("/"),
              !path.contains("\0"),
              !path.contains("\n"),
              !path.contains("\t") else {
            return nil
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard categoryAllows(url: url, category: category),
              let metadata = fileMetadata(at: url),
              metadata.isRegularFile,
              !metadata.isSymbolicLink,
              metadata.deviceID == expectedDeviceID,
              metadata.fileID == expectedFileID,
              metadata.modifiedDate == expectedModifiedDate,
              metadata.sizeBytes == expectedSizeBytes,
              referenceDate.timeIntervalSince(metadata.modifiedDate) >= minimumAge,
              !CleanupPreferences.isWhitelisted(url.path) else {
            return nil
        }
        return SystemCleanupItem(
            path: url.path,
            name: url.lastPathComponent,
            category: category,
            sizeBytes: metadata.sizeBytes,
            modifiedDate: metadata.modifiedDate,
            deviceID: metadata.deviceID,
            fileID: metadata.fileID
        )
    }

    private static func categoryAllows(url: URL, category: SystemCleanupCategory) -> Bool {
        switch category {
        case .systemCaches:
            let root = "/Library/Caches"
            let extensionName = url.pathExtension.lowercased()
            return pathIsInside(url.path, root: root)
                && canonicalPathIsInside(url, root: root)
                && pathDepth(url.path, root: root) <= 5
                && ["cache", "tmp", "log"].contains(extensionName)
        case .crashReports:
            let root = "/Library/Logs/DiagnosticReports"
            return pathIsInside(url.path, root: root)
                && canonicalPathIsInside(url, root: root)
                && pathDepth(url.path, root: root) <= 1
        case .systemLogs:
            let root = "/private/var/log"
            let extensionName = url.pathExtension.lowercased()
            return pathIsInside(url.path, root: root)
                && canonicalPathIsInside(url, root: root)
                && pathDepth(url.path, root: root) <= 3
                && ["log", "gz", "asl"].contains(extensionName)
        case .thirdPartyLogs:
            if pathsEqual(url.path, "/Library/Logs/adobegc.log") {
                return canonicalPathIsInside(url, root: "/Library/Logs")
            }
            let roots = ["/Library/Logs/Adobe", "/Library/Logs/CreativeCloud"]
            return roots.contains { root in
                pathIsInside(url.path, root: root)
                    && canonicalPathIsInside(url, root: root)
                    && pathDepth(url.path, root: root) <= 5
            }
        }
    }

    private static func fileMetadata(at url: URL) -> (
        deviceID: UInt64,
        fileID: UInt64,
        modifiedDate: Date,
        sizeBytes: UInt64,
        isRegularFile: Bool,
        isSymbolicLink: Bool
    )? {
        var value = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &value)
        }
        guard result == 0, value.st_blocks >= 0 else { return nil }
        let kind = value.st_mode & S_IFMT
        return (
            UInt64(value.st_dev),
            UInt64(value.st_ino),
            Date(timeIntervalSince1970: TimeInterval(value.st_mtimespec.tv_sec)),
            UInt64(value.st_blocks) * 512,
            kind == S_IFREG,
            kind == S_IFLNK
        )
    }

    private static func canonicalPathIsInside(_ url: URL, root: String) -> Bool {
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL.path
        return pathIsInside(canonical, root: root)
    }

    private static func pathDepth(_ path: String, root: String) -> Int {
        guard pathIsInside(path, root: root), !pathsEqual(path, root) else { return 0 }
        return String(path.dropFirst(root.count + 1)).split(separator: "/").count
    }

    private static func pathIsInside(_ path: String, root: String) -> Bool {
        pathsEqual(path, root) || path.lowercased().hasPrefix(root.lowercased() + "/")
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
        timeoutWork.cancel()
        return CommandOutput(
            status: process.terminationStatus,
            output: String(decoding: data, as: UTF8.self),
            timedOut: process.terminationReason == .uncaughtSignal
                && process.terminationStatus == SIGTERM
        )
    }

    private static let administratorScript = """
    on run argv
        do shell script (item 1 of argv) with administrator privileges
    end run
    """

    private static let scanShellScript = #"""
    set -o pipefail
    scan_file=$(/usr/bin/mktemp /private/tmp/com.seaony.Moni.system-scan.XXXXXX) || exit 70
    trap '/bin/rm -f "$scan_file"' EXIT HUP INT TERM

    scan_family() {
        scan_category=$1
        scan_root=$2
        [ -d "$scan_root" ] && [ ! -L "$scan_root" ] || return 0
        case "$scan_category" in
            systemCaches)
                /usr/bin/find "$scan_root" -maxdepth 5 -type f -mtime +7 \( -name '*.cache' -o -name '*.tmp' -o -name '*.log' \) -print0 > "$scan_file"
                ;;
            crashReports)
                /usr/bin/find "$scan_root" -maxdepth 1 -type f -mtime +7 -print0 > "$scan_file"
                ;;
            systemLogs)
                /usr/bin/find "$scan_root" -maxdepth 3 -type f -mtime +7 \( -name '*.log' -o -name '*.gz' -o -name '*.asl' \) -print0 > "$scan_file"
                ;;
            thirdPartyLogs)
                /usr/bin/find "$scan_root" -maxdepth 5 -type f -mtime +7 -print0 > "$scan_file"
                ;;
            adobeGCLog)
                /usr/bin/find "$scan_root" -maxdepth 1 -type f -name 'adobegc.log' -mtime +7 -print0 > "$scan_file"
                ;;
            *)
                return 1
                ;;
        esac
        scan_result=$?
        if [ "$scan_result" -ne 0 ]; then
            printf 'ERROR\t%s\n' "$scan_category"
            return 0
        fi

        while IFS= read -r -d '' scan_path; do
            case "$scan_path" in *$'\n'*|*$'\t'*) printf 'UNREADABLE\t%s\n' "$scan_category"; continue ;; esac
            scan_identity=$(/usr/bin/stat -f '%d:%i:%m:%b' "$scan_path" 2>/dev/null) || {
                printf 'UNREADABLE\t%s\n' "$scan_category"
                continue
            }
            scan_device=${scan_identity%%:*}
            scan_remainder=${scan_identity#*:}
            scan_inode=${scan_remainder%%:*}
            scan_remainder=${scan_remainder#*:}
            scan_mtime=${scan_remainder%%:*}
            scan_blocks=${scan_remainder##*:}
            scan_size=$((scan_blocks * 512))
            scan_encoded=$(printf '%s' "$scan_path" | /usr/bin/base64 -b 0) || {
                printf 'UNREADABLE\t%s\n' "$scan_category"
                continue
            }
            output_category=$scan_category
            [ "$output_category" = 'adobeGCLog' ] && output_category='thirdPartyLogs'
            printf 'ITEM\t%s\t%s\t%s\t%s\t%s\t%s\n' "$output_category" "$scan_device" "$scan_inode" "$scan_mtime" "$scan_size" "$scan_encoded"
        done < "$scan_file"
    }

    scan_family systemCaches /Library/Caches
    scan_family crashReports /Library/Logs/DiagnosticReports
    scan_family systemLogs /private/var/log
    scan_family thirdPartyLogs /Library/Logs/Adobe
    scan_family thirdPartyLogs /Library/Logs/CreativeCloud
    scan_family adobeGCLog /Library/Logs
    """#
}
