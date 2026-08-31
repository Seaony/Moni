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
    case staleWallpaperDownloads
    case rebuildableServiceCaches
    case browserCodeSignatureCaches
    case rebuildableGPUCaches
    case systemDiagnostics
    case powerLogs
    case memoryExceptionReports

    var titleKey: String {
        switch self {
        case .systemCaches: "System caches"
        case .crashReports: "System crash reports"
        case .systemLogs: "System logs"
        case .thirdPartyLogs: "Third-party system logs"
        case .staleWallpaperDownloads: "Stale wallpaper downloads"
        case .rebuildableServiceCaches: "Rebuildable system caches"
        case .browserCodeSignatureCaches: "Browser code signature caches"
        case .rebuildableGPUCaches: "Rebuildable GPU caches"
        case .systemDiagnostics: "System diagnostic logs"
        case .powerLogs: "Power logs"
        case .memoryExceptionReports: "Memory exception reports"
        }
    }
}

nonisolated enum SystemCleanupItemKind: String, Sendable {
    case file
    case directory
}

nonisolated struct SystemCleanupItem: Identifiable, Sendable {
    let path: String
    let name: String
    let category: SystemCleanupCategory
    let kind: SystemCleanupItemKind
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
    let activePowerLogNotice: SystemCleanupNotice?
}

nonisolated struct SystemCleanupNotice: Sendable {
    let path: String
    let sizeBytes: UInt64
}

nonisolated struct SystemCleanupPlan: Identifiable, Sendable {
    let cleanupPlan: CleanupPlan
    let items: [SystemCleanupItem]
    let activePowerLogNotice: SystemCleanupNotice?

    var id: UUID { cleanupPlan.id }
}

nonisolated enum SystemCleanupService {
    private struct CommandOutput: Sendable {
        let status: Int32
        let output: String
        let timedOut: Bool
    }

    private static let scriptExecutable = "/usr/bin/osascript"
    private static let minimumAge: TimeInterval = 7 * 24 * 60 * 60
    private static let cleanupPlanLifetime: TimeInterval = 5 * 60

    static func scan() async -> SystemCleanupSnapshot {
        await Task.detached(priority: .userInitiated) {
            scanSynchronously(referenceDate: Date())
        }.value
    }

    static func previewCleanup(
        items: [SystemCleanupItem],
        activePowerLogNotice: SystemCleanupNotice?
    ) async -> SystemCleanupPlan {
        let plan = await Task.detached(priority: .utility) {
            previewCleanupSynchronously(
                items: items,
                activePowerLogNotice: activePowerLogNotice
            )
        }.value
        await CleanupService.shared.recordPreview(plan.cleanupPlan)
        return plan
    }

    static func executeCleanup(_ plan: SystemCleanupPlan) async -> CleanupRunResult {
        let result = await Task.detached(priority: .userInitiated) {
            executeCleanupSynchronously(plan)
        }.value
        let previewRejectedPaths = Set(plan.cleanupPlan.rejectedItems.map(\.path))
        await CleanupService.shared.recordRunResult(
            CleanupRunResult(
                trashedPaths: result.trashedPaths,
                rejectedItems: result.rejectedItems.filter {
                    !previewRejectedPaths.contains($0.path)
                },
                failedPaths: result.failedPaths
            ),
            scope: .maintenance
        )
        return result
    }

    private static func scanSynchronously(referenceDate: Date) -> SystemCleanupSnapshot {
        guard FileManager.default.isExecutableFile(atPath: scriptExecutable) else {
            return SystemCleanupSnapshot(
                state: .unavailable,
                items: [],
                unreadableItemCount: 0,
                activePowerLogNotice: nil
            )
        }
        let shellScript = "scan_user_id=\(getuid())\n" + scanShellScript
        let result = run(
            scriptExecutable,
            arguments: ["-e", administratorScript, shellScript],
            timeout: 120
        )
        if result.timedOut {
            return SystemCleanupSnapshot(
                state: .failed,
                items: [],
                unreadableItemCount: 0,
                activePowerLogNotice: nil
            )
        }
        if result.status != 0 {
            let cancelled = result.output.localizedCaseInsensitiveContains("User canceled")
                || result.output.contains("(-128)")
            return SystemCleanupSnapshot(
                state: cancelled ? .cancelled : .failed,
                items: [],
                unreadableItemCount: 0,
                activePowerLogNotice: nil
            )
        }

        var itemsByPath: [String: SystemCleanupItem] = [:]
        var unreadableItemCount = 0
        var scanFailed = false
        var activePowerLogNotice: SystemCleanupNotice?
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
            if recordType == "NOTICE" {
                if fields.count == 4,
                   fields[1] == "activePowerLog",
                   let sizeBytes = UInt64(fields[2]),
                   let pathData = Data(base64Encoded: String(fields[3])),
                   let path = String(data: pathData, encoding: .utf8) {
                    activePowerLogNotice = validatedActivePowerLogNotice(
                        path: path,
                        expectedSizeBytes: sizeBytes
                    )
                }
                continue
            }
            guard recordType == "ITEM",
                  fields.count == 8,
                  let kind = SystemCleanupItemKind(rawValue: String(fields[1])),
                  let category = SystemCleanupCategory(rawValue: String(fields[2])),
                  let deviceID = UInt64(fields[3]),
                  let fileID = UInt64(fields[4]),
                  let modificationSeconds = Int64(fields[5]),
                  let sizeBytes = UInt64(fields[6]),
                  let pathData = Data(base64Encoded: String(fields[7])),
                  let path = String(data: pathData, encoding: .utf8) else {
                scanFailed = true
                continue
            }
            let modifiedDate = Date(timeIntervalSince1970: TimeInterval(modificationSeconds))
            guard let item = validatedItem(
                path: path,
                category: category,
                kind: kind,
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
                unreadableItemCount: unreadableItemCount,
                activePowerLogNotice: activePowerLogNotice
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
            unreadableItemCount: unreadableItemCount,
            activePowerLogNotice: activePowerLogNotice
        )
    }

    private static func validatedActivePowerLogNotice(
        path: String,
        expectedSizeBytes: UInt64
    ) -> SystemCleanupNotice? {
        let warningThresholdBytes: UInt64 = 10 * 1024 * 1024 * 1024
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard isActivePowerLogPath(url.path),
              expectedSizeBytes >= warningThresholdBytes,
              let metadata = fileMetadata(at: url),
              metadata.isRegularFile,
              !metadata.isSymbolicLink,
              metadata.logicalSizeBytes == expectedSizeBytes else {
            return nil
        }
        return SystemCleanupNotice(path: url.path, sizeBytes: expectedSizeBytes)
    }

    private static func executeCleanupSynchronously(_ plan: SystemCleanupPlan) -> CleanupRunResult {
        guard plan.cleanupPlan.scope == .maintenance else {
            return CleanupRunResult(
                trashedPaths: [],
                rejectedItems: plan.cleanupPlan.rejectedItems + plan.cleanupPlan.candidates.map {
                    CleanupRejectedItem(path: $0.path, reason: .protected)
                },
                failedPaths: []
            )
        }
        guard Date().timeIntervalSince(plan.cleanupPlan.createdAt) <= cleanupPlanLifetime else {
            return CleanupRunResult(
                trashedPaths: [],
                rejectedItems: plan.cleanupPlan.rejectedItems + plan.cleanupPlan.candidates.map {
                    CleanupRejectedItem(path: $0.path, reason: .expired)
                },
                failedPaths: []
            )
        }

        let referenceDate = Date()
        let itemsByPath = Dictionary(uniqueKeysWithValues: plan.items.map { ($0.path, $0) })
        var rejectedItems = plan.cleanupPlan.rejectedItems
        var failedPaths: [String] = []
        guard let trash = userTrashIdentity() else {
            return CleanupRunResult(
                trashedPaths: [],
                rejectedItems: rejectedItems,
                failedPaths: plan.cleanupPlan.candidates.map(\.path)
            )
        }

        var eligible: [(
            candidate: CleanupCandidate,
            item: SystemCleanupItem,
            destination: String
        )] = []
        var reservedDestinations: Set<String> = []
        for candidate in plan.cleanupPlan.candidates {
            guard let item = itemsByPath[candidate.path],
                  candidate.device == item.deviceID,
                  candidate.inode == item.fileID,
                  candidate.device == trash.deviceID,
                  validatedItem(
                      path: item.path,
                      category: item.category,
                      kind: item.kind,
                      expectedDeviceID: item.deviceID,
                      expectedFileID: item.fileID,
                      expectedModifiedDate: item.modifiedDate,
                      expectedSizeBytes: item.sizeBytes,
                      referenceDate: referenceDate
                  ) != nil else {
                rejectedItems.append(CleanupRejectedItem(path: candidate.path, reason: .changed))
                continue
            }
            guard let destination = uniqueTrashDestination(
                for: item.name,
                in: trash.path,
                reserved: &reservedDestinations
            ) else {
                failedPaths.append(candidate.path)
                continue
            }
            eligible.append((candidate, item, destination))
        }
        guard !eligible.isEmpty else {
            return CleanupRunResult(
                trashedPaths: [],
                rejectedItems: rejectedItems,
                failedPaths: failedPaths
            )
        }

        var arguments = [
            "-e", cleanupAdministratorScript,
            cleanupShellScript,
            trash.path,
            "\(trash.deviceID):\(trash.fileID):\(trash.ownerID)"
        ]
        for entry in eligible {
            arguments.append(entry.candidate.path)
            arguments.append(entry.destination)
            arguments.append(
                "\(entry.item.deviceID):\(entry.item.fileID):\(Int64(entry.item.modifiedDate.timeIntervalSince1970))"
            )
            arguments.append(String(entry.item.sizeBytes))
            arguments.append(entry.item.category.rawValue)
            arguments.append(entry.item.kind.rawValue)
        }
        let execution = run(scriptExecutable, arguments: arguments, timeout: 300)
        let trashedIndexes = Set(execution.output.split(whereSeparator: \.isNewline).compactMap { line -> Int? in
            guard line.hasPrefix("TRASHED:"),
                  let index = Int(line.dropFirst("TRASHED:".count)) else {
                return nil
            }
            return index
        })
        var trashedPaths: [String] = []
        for (offset, entry) in eligible.enumerated() {
            if trashedIndexes.contains(offset + 1),
               !pathExists(at: entry.candidate.path),
               pathExists(at: entry.destination) {
                trashedPaths.append(entry.candidate.path)
            } else {
                failedPaths.append(entry.candidate.path)
            }
        }
        return CleanupRunResult(
            trashedPaths: trashedPaths,
            rejectedItems: rejectedItems,
            failedPaths: failedPaths
        )
    }

    private static func previewCleanupSynchronously(
        items: [SystemCleanupItem],
        activePowerLogNotice: SystemCleanupNotice?
    ) -> SystemCleanupPlan {
        let referenceDate = Date()
        var candidates: [CleanupCandidate] = []
        var rejectedItems: [CleanupRejectedItem] = []
        var seenCanonicalPaths: Set<String> = []

        for item in items {
            if CleanupPreferences.isWhitelisted(item.path) {
                rejectedItems.append(CleanupRejectedItem(path: item.path, reason: .whitelisted))
                continue
            }
            guard let current = validatedItem(
                path: item.path,
                category: item.category,
                kind: item.kind,
                expectedDeviceID: item.deviceID,
                expectedFileID: item.fileID,
                expectedModifiedDate: item.modifiedDate,
                expectedSizeBytes: item.sizeBytes,
                referenceDate: referenceDate
            ) else {
                rejectedItems.append(CleanupRejectedItem(path: item.path, reason: .changed))
                continue
            }
            let canonicalPath = URL(fileURLWithPath: current.path)
                .resolvingSymlinksInPath()
                .standardizedFileURL.path
            guard seenCanonicalPaths.insert(canonicalPath).inserted else { continue }
            candidates.append(CleanupCandidate(
                path: current.path,
                canonicalPath: canonicalPath,
                device: current.deviceID,
                inode: current.fileID
            ))
        }

        candidates.sort {
            let lhsDepth = $0.canonicalPath.split(separator: "/").count
            let rhsDepth = $1.canonicalPath.split(separator: "/").count
            if lhsDepth != rhsDepth { return lhsDepth < rhsDepth }
            return $0.canonicalPath.localizedStandardCompare($1.canonicalPath) == .orderedAscending
        }
        candidates = candidates.reduce(into: []) { result, candidate in
            guard !result.contains(where: {
                pathIsInside(candidate.canonicalPath, root: $0.canonicalPath)
            }) else {
                return
            }
            result.append(candidate)
        }

        return SystemCleanupPlan(
            cleanupPlan: CleanupPlan(
                id: UUID(),
                createdAt: referenceDate,
                scope: .maintenance,
                candidates: candidates,
                rejectedItems: rejectedItems
            ),
            items: items,
            activePowerLogNotice: activePowerLogNotice
        )
    }

    private static func userTrashIdentity() -> (
        path: String,
        deviceID: UInt64,
        fileID: UInt64,
        ownerID: UInt32
    )? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".Trash", isDirectory: true)
            .standardizedFileURL.path
        if !pathExists(at: path) {
            do {
                try FileManager.default.createDirectory(
                    atPath: path,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                return nil
            }
        }
        var value = stat()
        guard path.withCString({ lstat($0, &value) }) == 0,
              value.st_mode & S_IFMT == S_IFDIR,
              value.st_uid == getuid() else {
            return nil
        }
        return (path, UInt64(value.st_dev), UInt64(value.st_ino), value.st_uid)
    }

    private static func uniqueTrashDestination(
        for name: String,
        in trashPath: String,
        reserved: inout Set<String>
    ) -> String? {
        guard !name.isEmpty, !name.contains("/") else { return nil }
        let original = URL(fileURLWithPath: trashPath, isDirectory: true)
            .appendingPathComponent(name)
            .path
        if !pathExists(at: original), reserved.insert(original).inserted { return original }

        let url = URL(fileURLWithPath: name)
        let extensionName = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        for _ in 0..<2 {
            let suffix = UUID().uuidString
            let uniqueName = extensionName.isEmpty
                ? "\(stem) \(suffix)"
                : "\(stem) \(suffix).\(extensionName)"
            let destination = URL(fileURLWithPath: trashPath, isDirectory: true)
                .appendingPathComponent(uniqueName)
                .path
            if !pathExists(at: destination), reserved.insert(destination).inserted {
                return destination
            }
        }
        return nil
    }

    private static func pathExists(at path: String) -> Bool {
        var value = stat()
        return path.withCString { lstat($0, &value) } == 0
    }

    private static func validatedItem(
        path: String,
        category: SystemCleanupCategory,
        kind: SystemCleanupItemKind,
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
        let directoryCategories: Set<SystemCleanupCategory> = [
            .rebuildableServiceCaches, .browserCodeSignatureCaches, .rebuildableGPUCaches
        ]
        let minimumItemAge = category == .memoryExceptionReports
            ? 30 * 24 * 60 * 60
            : minimumAge
        guard (directoryCategories.contains(category) && kind == .directory)
                || (!directoryCategories.contains(category) && kind == .file),
              categoryAllows(url: url, category: category),
              kind == .directory
                || referenceDate.timeIntervalSince(expectedModifiedDate) >= minimumItemAge,
              !isEndpointSecurityPath(url.path),
              !CleanupPreferences.isWhitelisted(url.path) else {
            return nil
        }
        if let metadata = fileMetadata(at: url) {
            guard (kind == .file && metadata.isRegularFile)
                    || (kind == .directory && metadata.isDirectory),
                  !metadata.isSymbolicLink,
                  metadata.deviceID == expectedDeviceID,
                  metadata.fileID == expectedFileID,
                  metadata.modifiedDate == expectedModifiedDate,
                  kind == .directory || metadata.sizeBytes == expectedSizeBytes else {
                return nil
            }
        } else if category != .memoryExceptionReports || url.path != path {
            return nil
        }
        return SystemCleanupItem(
            path: url.path,
            name: url.lastPathComponent,
            category: category,
            kind: kind,
            sizeBytes: expectedSizeBytes,
            modifiedDate: expectedModifiedDate,
            deviceID: expectedDeviceID,
            fileID: expectedFileID
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
        case .staleWallpaperDownloads:
            let root = "/private/var/folders"
            let components = url.pathComponents
            guard let temporaryIndex = components.firstIndex(of: "T"),
                  temporaryIndex == 6,
                  components.indices.contains(temporaryIndex + 1),
                  components[temporaryIndex + 1] == "com.apple.idleassetsd" else {
                return false
            }
            return pathIsInside(url.path, root: root)
                && canonicalPathIsInside(url, root: root)
                && pathDepth(url.path, root: root) <= 10
                && url.lastPathComponent.hasPrefix("CFNetworkDownload_")
                && url.pathExtension.lowercased() == "tmp"
        case .rebuildableServiceCaches:
            return pathsEqual(url.path, "/Library/Caches/com.apple.iconservices.store")
                && canonicalPathIsInside(url, root: "/Library/Caches")
        case .browserCodeSignatureCaches:
            let root = "/private/var/folders"
            let components = url.pathComponents
            guard let cloneRootIndex = components.firstIndex(of: "X"),
                  cloneRootIndex == 6 else {
                return false
            }
            return pathIsInside(url.path, root: root)
                && canonicalPathIsInside(url, root: root)
                && pathDepth(url.path, root: root) <= 5
                && url.lastPathComponent.hasSuffix(".code_sign_clone")
        case .rebuildableGPUCaches:
            let root = "/private/var/folders"
            let components = url.pathComponents
            guard let cacheRootIndex = components.firstIndex(of: "C"),
                  cacheRootIndex == 6,
                  components.count == 9 else {
                return false
            }
            let allowedNames = ["com.apple.gpuarchiver", "com.apple.metal", "com.apple.metalfe"]
            return pathIsInside(url.path, root: root)
                && canonicalPathIsInside(url, root: root)
                && pathDepth(url.path, root: root) == 5
                && allowedNames.contains(url.lastPathComponent)
        case .systemDiagnostics:
            let roots = ["/private/var/db/diagnostics", "/private/var/db/DiagnosticPipeline"]
            return roots.contains { root in
                pathIsInside(url.path, root: root)
                    && canonicalPathIsInside(url, root: root)
                    && pathDepth(url.path, root: root) <= 5
            }
        case .powerLogs:
            let root = "/private/var/db/powerlog"
            return pathIsInside(url.path, root: root)
                && canonicalPathIsInside(url, root: root)
                && pathDepth(url.path, root: root) <= 5
                && !isActivePowerLogPath(url.path)
        case .memoryExceptionReports:
            let root = "/private/var/db/reportmemoryexception/MemoryLimitViolations"
            return pathIsInside(url.path, root: root)
                && canonicalPathIsInside(url, root: root)
                && pathDepth(url.path, root: root) <= 5
        }
    }

    private static func isActivePowerLogPath(_ path: String) -> Bool {
        let database = "/private/var/db/powerlog/Library/PerfPowerTelemetry/BackgroundProcessing/CurrentBackgroundProcessingDB.BGSQL"
        return [database, database + "-wal", database + "-shm"].contains {
            pathsEqual(path, $0)
        }
    }

    private static func fileMetadata(at url: URL) -> (
        deviceID: UInt64,
        fileID: UInt64,
        modifiedDate: Date,
        sizeBytes: UInt64,
        logicalSizeBytes: UInt64,
        isRegularFile: Bool,
        isDirectory: Bool,
        isSymbolicLink: Bool
    )? {
        var value = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &value)
        }
        guard result == 0, value.st_blocks >= 0, value.st_size >= 0 else { return nil }
        let kind = value.st_mode & S_IFMT
        let (sizeBytes, overflow) = UInt64(value.st_blocks).multipliedReportingOverflow(by: 512)
        guard !overflow else { return nil }
        return (
            UInt64(value.st_dev),
            UInt64(value.st_ino),
            Date(timeIntervalSince1970: TimeInterval(value.st_mtimespec.tv_sec)),
            sizeBytes,
            UInt64(value.st_size),
            kind == S_IFREG,
            kind == S_IFDIR,
            kind == S_IFLNK
        )
    }

    private static func canonicalPathIsInside(_ url: URL, root: String) -> Bool {
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL.path
        return pathIsInside(canonical, root: root)
    }

    private static func isEndpointSecurityPath(_ path: String) -> Bool {
        guard path.lowercased().hasPrefix("/private/var/folders/") else { return false }
        let lowercased = path.lowercased()
        let prefixes = [
            "com.crowdstrike.", "com.sentinelone.", "com.sentinel-labs.", "com.eset.",
            "com.jamf.", "com.jamfsoftware.", "com.paloaltonetworks.",
            "com.cisco.anyconnect", "com.cisco.secureclient"
        ]
        return prefixes.contains(where: lowercased.contains)
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

    private static let cleanupAdministratorScript = #"""
    on run argv
        set commandText to item 1 of argv
        set trashPath to item 2 of argv
        set expectedTrashIdentity to item 3 of argv
        set commandText to commandText & "; trash_path=" & quoted form of trashPath & "; expected_trash_identity=" & quoted form of expectedTrashIdentity & "; "
        set argumentCount to count of argv
        set candidateIndex to 0
        repeat with argumentIndex from 4 to argumentCount by 6
            set candidateIndex to candidateIndex + 1
            set candidateIndexText to candidateIndex as text
            set sourcePath to item argumentIndex of argv
            set destinationPath to item (argumentIndex + 1) of argv
            set expectedIdentity to item (argumentIndex + 2) of argv
            set expectedSize to item (argumentIndex + 3) of argv
            set categoryName to item (argumentIndex + 4) of argv
            set itemKind to item (argumentIndex + 5) of argv
            set commandText to commandText & "( source_path=" & quoted form of sourcePath & "; destination_path=" & quoted form of destinationPath & "; expected_identity=" & quoted form of expectedIdentity & "; expected_size=" & quoted form of expectedSize & "; category_name=" & quoted form of categoryName & "; item_kind=" & quoted form of itemKind & "; move_system_candidate \"$source_path\" \"$destination_path\" \"$expected_identity\" \"$expected_size\" \"$category_name\" \"$item_kind\" ) && printf 'TRASHED:%s\\n' " & candidateIndexText & " || printf 'FAILED:%s\\n' " & candidateIndexText & "; "
        end repeat
        do shell script commandText with administrator privileges
    end run
    """#

    private static let cleanupShellScript = #"""
    set -o pipefail

    path_depth_ok() {
        depth_path=$1
        depth_root=$2
        depth_limit=$3
        depth_relative=${depth_path#"$depth_root"/}
        [ "$depth_relative" != "$depth_path" ] || return 1
        printf '%s\n' "$depth_relative" | /usr/bin/awk -F/ -v limit="$depth_limit" 'NF <= limit { valid=1 } END { exit valid ? 0 : 1 }'
    }

    active_powerlog_path() {
        powerlog_path=$(printf '%s' "$1" | /usr/bin/tr '[:upper:]' '[:lower:]') || return 0
        case "$powerlog_path" in
            /private/var/db/powerlog/library/perfpowertelemetry/backgroundprocessing/currentbackgroundprocessingdb.bgsql|\
            /private/var/db/powerlog/library/perfpowertelemetry/backgroundprocessing/currentbackgroundprocessingdb.bgsql-wal|\
            /private/var/db/powerlog/library/perfpowertelemetry/backgroundprocessing/currentbackgroundprocessingdb.bgsql-shm) return 0 ;;
            *) return 1 ;;
        esac
    }

    system_candidate_path() {
        candidate_path=$1
        candidate_category=$2
        candidate_name=$(/usr/bin/basename "$candidate_path") || return 1
        case "$candidate_category" in
            systemCaches)
                case "$candidate_path" in /Library/Caches/*) ;; *) return 1 ;; esac
                path_depth_ok "$candidate_path" /Library/Caches 5 || return 1
                case "$candidate_name" in *.cache|*.tmp|*.log) return 0 ;; *) return 1 ;; esac
                ;;
            crashReports)
                case "$candidate_path" in /Library/Logs/DiagnosticReports/*) ;; *) return 1 ;; esac
                path_depth_ok "$candidate_path" /Library/Logs/DiagnosticReports 1
                ;;
            systemLogs)
                case "$candidate_path" in /private/var/log/*) ;; *) return 1 ;; esac
                path_depth_ok "$candidate_path" /private/var/log 3 || return 1
                case "$candidate_name" in *.log|*.gz|*.asl) return 0 ;; *) return 1 ;; esac
                ;;
            thirdPartyLogs)
                case "$candidate_path" in
                    /Library/Logs/adobegc.log) return 0 ;;
                    /Library/Logs/Adobe/*) path_depth_ok "$candidate_path" /Library/Logs/Adobe 5 ;;
                    /Library/Logs/CreativeCloud/*) path_depth_ok "$candidate_path" /Library/Logs/CreativeCloud 5 ;;
                    *) return 1 ;;
                esac
                ;;
            staleWallpaperDownloads)
                printf '%s\n' "$candidate_path" | /usr/bin/awk -F/ 'NF >= 9 && NF <= 13 && $2 == "private" && $3 == "var" && $4 == "folders" && $7 == "T" && $8 == "com.apple.idleassetsd" { valid=1 } END { exit valid ? 0 : 1 }' || return 1
                case "$candidate_name" in CFNetworkDownload_*.tmp) return 0 ;; *) return 1 ;; esac
                ;;
            rebuildableServiceCaches)
                [ "$candidate_path" = '/Library/Caches/com.apple.iconservices.store' ]
                ;;
            browserCodeSignatureCaches)
                printf '%s\n' "$candidate_path" | /usr/bin/awk -F/ 'NF >= 8 && NF <= 9 && $2 == "private" && $3 == "var" && $4 == "folders" && $7 == "X" { valid=1 } END { exit valid ? 0 : 1 }' || return 1
                case "$candidate_name" in *.code_sign_clone) return 0 ;; *) return 1 ;; esac
                ;;
            rebuildableGPUCaches)
                printf '%s\n' "$candidate_path" | /usr/bin/awk -F/ 'NF == 9 && $2 == "private" && $3 == "var" && $4 == "folders" && $7 == "C" { valid=1 } END { exit valid ? 0 : 1 }' || return 1
                case "$candidate_name" in com.apple.gpuarchiver|com.apple.metal|com.apple.metalfe) return 0 ;; *) return 1 ;; esac
                ;;
            systemDiagnostics)
                case "$candidate_path" in
                    /private/var/db/diagnostics/*) path_depth_ok "$candidate_path" /private/var/db/diagnostics 5 ;;
                    /private/var/db/DiagnosticPipeline/*) path_depth_ok "$candidate_path" /private/var/db/DiagnosticPipeline 5 ;;
                    *) return 1 ;;
                esac
                ;;
            powerLogs)
                case "$candidate_path" in /private/var/db/powerlog/*) ;; *) return 1 ;; esac
                path_depth_ok "$candidate_path" /private/var/db/powerlog 5 || return 1
                ! active_powerlog_path "$candidate_path"
                ;;
            memoryExceptionReports)
                case "$candidate_path" in /private/var/db/reportmemoryexception/MemoryLimitViolations/*) ;; *) return 1 ;; esac
                path_depth_ok "$candidate_path" /private/var/db/reportmemoryexception/MemoryLimitViolations 5
                ;;
            *)
                return 1
                ;;
        esac
    }

    endpoint_security_path() {
        security_path=$(printf '%s' "$1" | /usr/bin/tr '[:upper:]' '[:lower:]') || return 0
        case "$security_path" in
            *com.crowdstrike.*|*com.sentinelone.*|*com.sentinel-labs.*|*com.eset.*|*com.jamf.*|*com.jamfsoftware.*|*com.paloaltonetworks.*|*com.cisco.anyconnect*|*com.cisco.secureclient*) return 0 ;;
            *) return 1 ;;
        esac
    }

    gpu_cache_stale() {
        gpu_path=$1
        gpu_recent=$(/usr/bin/find "$gpu_path" -type f -mtime -1 -print -quit 2>/dev/null) || return 1
        [ -z "$gpu_recent" ]
    }

    system_candidate_size() {
        size_path=$1
        size_kind=$2
        case "$size_kind" in
            file)
                size_blocks=$(/usr/bin/stat -f '%b' "$size_path" 2>/dev/null) || return 1
                printf '%s\n' "$((size_blocks * 512))"
                ;;
            directory)
                size_kilobytes=$(/usr/bin/du -sk "$size_path" 2>/dev/null | /usr/bin/awk 'NR == 1 { print $1 }') || return 1
                case "$size_kilobytes" in ''|*[!0-9]*) return 1 ;; esac
                printf '%s\n' "$((size_kilobytes * 1024))"
                ;;
            *)
                return 1
                ;;
        esac
    }

    move_system_candidate() {
        move_source=$1
        move_destination=$2
        move_expected_identity=$3
        move_expected_size=$4
        move_category=$5
        move_kind=$6
        system_candidate_path "$move_source" "$move_category" || return 1
        endpoint_security_path "$move_source" && return 1
        case "$move_kind:$move_category" in
            directory:rebuildableServiceCaches) [ -d "$move_source" ] || return 1 ;;
            directory:browserCodeSignatureCaches) [ -d "$move_source" ] || return 1 ;;
            directory:rebuildableGPUCaches) [ -d "$move_source" ] || return 1 ;;
            file:rebuildableServiceCaches|file:browserCodeSignatureCaches|file:rebuildableGPUCaches) return 1 ;;
            file:*) [ -f "$move_source" ] || return 1 ;;
            *) return 1 ;;
        esac
        [ ! -L "$move_source" ] || return 1
        move_identity=$(/usr/bin/stat -f '%d:%i:%m' "$move_source" 2>/dev/null) || return 1
        [ "$move_identity" = "$move_expected_identity" ] || return 1
        if [ "$move_category" = 'rebuildableGPUCaches' ]; then
            move_cache_root=$(/usr/bin/dirname "$move_source") || return 1
            move_cache_root=$(/usr/bin/dirname "$move_cache_root") || return 1
            move_cache_owner=$(/usr/bin/stat -f '%u' "$move_cache_root" 2>/dev/null) || return 1
            move_expected_owner=${expected_trash_identity##*:}
            [ "$move_cache_owner" = "$move_expected_owner" ] || return 1
            gpu_cache_stale "$move_source" || return 1
        fi
        move_size=$(system_candidate_size "$move_source" "$move_kind") || return 1
        [ "$move_size" = "$move_expected_size" ] || return 1
        if [ "$move_kind" = 'file' ]; then
            move_mtime=${move_identity##*:}
            move_now=$(/bin/date +%s) || return 1
            move_minimum_age=604800
            [ "$move_category" = 'memoryExceptionReports' ] && move_minimum_age=2592000
            [ "$move_now" -ge "$move_mtime" ] && [ $((move_now - move_mtime)) -ge "$move_minimum_age" ] || return 1
        fi

        move_trash_identity=$(/usr/bin/stat -f '%d:%i:%u' "$trash_path" 2>/dev/null) || return 1
        [ "$move_trash_identity" = "$expected_trash_identity" ] || return 1
        [ -d "$trash_path" ] && [ ! -L "$trash_path" ] || return 1
        [ "$(/usr/bin/dirname "$move_destination")" = "$trash_path" ] || return 1
        [ ! -e "$move_destination" ] && [ ! -L "$move_destination" ] || return 1
        move_source_device=${move_identity%%:*}
        move_trash_device=${move_trash_identity%%:*}
        [ "$move_source_device" = "$move_trash_device" ] || return 1

        move_parent=$(/usr/bin/dirname "$move_source") || return 1
        move_canonical_parent=$(cd -P "$move_parent" 2>/dev/null && /bin/pwd -P) || return 1
        move_name=$(/usr/bin/basename "$move_source") || return 1
        move_canonical_source="$move_canonical_parent/$move_name"
        system_candidate_path "$move_canonical_source" "$move_category" || return 1

        move_final_identity=$(/usr/bin/stat -f '%d:%i:%m' "$move_source" 2>/dev/null) || return 1
        if [ "$move_category" = 'rebuildableGPUCaches' ]; then
            gpu_cache_stale "$move_source" || return 1
        fi
        move_final_size=$(system_candidate_size "$move_source" "$move_kind") || return 1
        move_final_trash_identity=$(/usr/bin/stat -f '%d:%i:%u' "$trash_path" 2>/dev/null) || return 1
        [ "$move_final_identity" = "$move_expected_identity" ] || return 1
        [ "$move_final_size" = "$move_expected_size" ] || return 1
        [ "$move_final_trash_identity" = "$expected_trash_identity" ] || return 1
        /bin/mv "$move_source" "$move_destination"
    }
    """#

    private static let scanShellScript = #"""
    set -o pipefail
    scan_file=$(/usr/bin/mktemp /private/tmp/com.seaony.Moni.system-scan.XXXXXX) || exit 70
    trap '/bin/rm -f "$scan_file"' EXIT HUP INT TERM

    active_powerlog_path() {
        powerlog_path=$(printf '%s' "$1" | /usr/bin/tr '[:upper:]' '[:lower:]') || return 0
        case "$powerlog_path" in
            /private/var/db/powerlog/library/perfpowertelemetry/backgroundprocessing/currentbackgroundprocessingdb.bgsql|\
            /private/var/db/powerlog/library/perfpowertelemetry/backgroundprocessing/currentbackgroundprocessingdb.bgsql-wal|\
            /private/var/db/powerlog/library/perfpowertelemetry/backgroundprocessing/currentbackgroundprocessingdb.bgsql-shm) return 0 ;;
            *) return 1 ;;
        esac
    }

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
            staleWallpaperDownloads)
                /usr/bin/find "$scan_root" -maxdepth 10 -type f -name 'CFNetworkDownload_*.tmp' -mtime +7 -path '*/T/com.apple.idleassetsd/*' -print0 > "$scan_file"
                ;;
            systemDiagnostics)
                /usr/bin/find "$scan_root" -maxdepth 5 -type f -mtime +7 -print0 > "$scan_file"
                ;;
            powerLogs)
                /usr/bin/find "$scan_root" -maxdepth 5 -type f -mtime +7 -print0 > "$scan_file"
                ;;
            memoryExceptionReports)
                /usr/bin/find "$scan_root" -maxdepth 5 -type f -mtime +30 -print0 > "$scan_file"
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
            if [ "$scan_category" = 'powerLogs' ] && active_powerlog_path "$scan_path"; then
                continue
            fi
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
            printf 'ITEM\tfile\t%s\t%s\t%s\t%s\t%s\t%s\n' "$output_category" "$scan_device" "$scan_inode" "$scan_mtime" "$scan_size" "$scan_encoded"
        done < "$scan_file"
    }

    scan_directory() {
        scan_category=$1
        scan_path=$2
        [ -d "$scan_path" ] && [ ! -L "$scan_path" ] || return 0
        scan_identity=$(/usr/bin/stat -f '%d:%i:%m' "$scan_path" 2>/dev/null) || {
            printf 'UNREADABLE\t%s\n' "$scan_category"
            return 0
        }
        scan_device=${scan_identity%%:*}
        scan_remainder=${scan_identity#*:}
        scan_inode=${scan_remainder%%:*}
        scan_mtime=${scan_remainder##*:}
        scan_kilobytes=$(/usr/bin/du -sk "$scan_path" 2>/dev/null | /usr/bin/awk 'NR == 1 { print $1 }') || {
            printf 'UNREADABLE\t%s\n' "$scan_category"
            return 0
        }
        case "$scan_kilobytes" in ''|*[!0-9]*) printf 'UNREADABLE\t%s\n' "$scan_category"; return 0 ;; esac
        scan_size=$((scan_kilobytes * 1024))
        scan_encoded=$(printf '%s' "$scan_path" | /usr/bin/base64 -b 0) || {
            printf 'UNREADABLE\t%s\n' "$scan_category"
            return 0
        }
        printf 'ITEM\tdirectory\t%s\t%s\t%s\t%s\t%s\t%s\n' "$scan_category" "$scan_device" "$scan_inode" "$scan_mtime" "$scan_size" "$scan_encoded"
    }

    scan_code_signature_directories() {
        scan_root=/private/var/folders
        [ -d "$scan_root" ] && [ ! -L "$scan_root" ] || return 0
        /usr/bin/find "$scan_root" -maxdepth 5 -type d \( -depth 3 ! -name X \) -prune -o -type d -name '*.code_sign_clone' -path '*/X/*' -print0 > "$scan_file"
        scan_result=$?
        if [ "$scan_result" -ne 0 ]; then
            printf 'ERROR\tbrowserCodeSignatureCaches\n'
            return 0
        fi
        while IFS= read -r -d '' scan_path; do
            scan_directory browserCodeSignatureCaches "$scan_path"
        done < "$scan_file"
    }

    scan_gpu_directories() {
        scan_root=/private/var/folders
        [ -d "$scan_root" ] && [ ! -L "$scan_root" ] || return 0
        /usr/bin/find "$scan_root" -maxdepth 8 -type d \( -depth 3 ! -name C \) -prune -o -type d \( -name 'com.apple.gpuarchiver' -o -name 'com.apple.metal' -o -name 'com.apple.metalfe' \) -path '*/C/*' -print0 > "$scan_file"
        scan_result=$?
        if [ "$scan_result" -ne 0 ]; then
            printf 'ERROR\trebuildableGPUCaches\n'
            return 0
        fi
        while IFS= read -r -d '' scan_path; do
            scan_cache_root=$(/usr/bin/dirname "$scan_path") || continue
            scan_cache_root=$(/usr/bin/dirname "$scan_cache_root") || continue
            scan_cache_owner=$(/usr/bin/stat -f '%u' "$scan_cache_root" 2>/dev/null) || continue
            [ "$scan_cache_owner" = "$scan_user_id" ] || continue
            scan_recent=$(/usr/bin/find "$scan_path" -type f -mtime -1 -print -quit 2>/dev/null) || {
                printf 'ERROR\trebuildableGPUCaches\n'
                continue
            }
            [ -z "$scan_recent" ] || continue
            scan_directory rebuildableGPUCaches "$scan_path"
        done < "$scan_file"
    }

    scan_family systemCaches /Library/Caches
    scan_family crashReports /Library/Logs/DiagnosticReports
    scan_family systemLogs /private/var/log
    scan_family thirdPartyLogs /Library/Logs/Adobe
    scan_family thirdPartyLogs /Library/Logs/CreativeCloud
    scan_family adobeGCLog /Library/Logs
    scan_family staleWallpaperDownloads /private/var/folders
    scan_directory rebuildableServiceCaches /Library/Caches/com.apple.iconservices.store
    scan_code_signature_directories
    scan_gpu_directories
    scan_family systemDiagnostics /private/var/db/diagnostics
    scan_family systemDiagnostics /private/var/db/DiagnosticPipeline
    scan_family powerLogs /private/var/db/powerlog
    scan_family memoryExceptionReports /private/var/db/reportmemoryexception/MemoryLimitViolations

    active_powerlog=/private/var/db/powerlog/Library/PerfPowerTelemetry/BackgroundProcessing/CurrentBackgroundProcessingDB.BGSQL
    if [ -f "$active_powerlog" ] && [ ! -L "$active_powerlog" ]; then
        active_powerlog_size=$(/usr/bin/stat -f '%z' "$active_powerlog" 2>/dev/null) || active_powerlog_size=''
        case "$active_powerlog_size" in
            ''|*[!0-9]*) ;;
            *)
                if [ "$active_powerlog_size" -ge 10737418240 ]; then
                    active_powerlog_encoded=$(printf '%s' "$active_powerlog" | /usr/bin/base64 -b 0) || active_powerlog_encoded=''
                    if [ -n "$active_powerlog_encoded" ]; then
                        printf 'NOTICE\tactivePowerLog\t%s\t%s\n' "$active_powerlog_size" "$active_powerlog_encoded"
                    fi
                fi
                ;;
        esac
    fi
    """#
}
