import Darwin
import Foundation

nonisolated enum InstallerSource: String, CaseIterable, Sendable {
    case applications
    case downloads
    case desktop
    case documents
    case publicFolder
    case library
    case shared
    case homebrew
    case iCloud
    case mail
    case telegram

    var titleKey: String {
        switch self {
        case .applications: "Applications"
        case .downloads: "Downloads"
        case .desktop: "Desktop"
        case .documents: "Documents"
        case .publicFolder: "Public"
        case .library: "Library"
        case .shared: "Shared"
        case .homebrew: "Homebrew"
        case .iCloud: "iCloud"
        case .mail: "Mail"
        case .telegram: "Telegram"
        }
    }
}

nonisolated enum InstallerKind: String, Sendable {
    case macOSApplication = "APP"
    case diskImage = "DMG"
    case package = "PKG"
    case metapackage = "MPKG"
    case opticalImage = "ISO"
    case signedArchive = "XIP"
    case zipArchive = "ZIP"
}

nonisolated struct InstallerCleanupItem: Identifiable, Sendable {
    let path: String
    let name: String
    let source: InstallerSource
    let kind: InstallerKind
    let sizeBytes: UInt64
    let modifiedDate: Date
    let filesystemDeviceID: UInt64?
    let filesystemFileID: UInt64?

    var id: String { path }
}

nonisolated struct InstallerCleanupSnapshot: Sendable {
    let items: [InstallerCleanupItem]
    let unreadableItemCount: Int
}

nonisolated struct InstallerCleanupPlan: Identifiable, Sendable {
    let cleanupPlan: CleanupPlan
    let items: [InstallerCleanupItem]

    var id: UUID { cleanupPlan.id }
}

nonisolated enum InstallerCleanupService {
    private struct SearchRoot: Sendable {
        let path: String
        let source: InstallerSource
    }

    private struct ScanResult: Sendable {
        let items: [InstallerCleanupItem]
        let unreadableItemCount: Int
    }

    private static let maximumScanDepth = 2
    private static let maximumZipEntries = 50
    private static let macOSInstallerMinimumAge: TimeInterval = 14 * 24 * 60 * 60
    private static let macOSInstallerSizeTimeout: TimeInterval = 30

    static func scan() async -> InstallerCleanupSnapshot {
        let rawResult = await Task.detached(priority: .utility) {
            scanSynchronously()
        }.value
        guard !Task.isCancelled else {
            return InstallerCleanupSnapshot(items: [], unreadableItemCount: 0)
        }
        let eligiblePaths = await CleanupService.shared.eligiblePaths(rawResult.items.map(\.path))
        return InstallerCleanupSnapshot(
            items: rawResult.items.filter { eligiblePaths.contains($0.path) },
            unreadableItemCount: rawResult.unreadableItemCount
        )
    }

    static func previewCleanup(items: [InstallerCleanupItem]) async -> InstallerCleanupPlan {
        let plan = await CleanupService.shared.preview(
            paths: items.map(\.path),
            scope: .installers
        )
        return InstallerCleanupPlan(cleanupPlan: plan, items: items)
    }

    static func executeCleanup(_ plan: InstallerCleanupPlan) async -> CleanupRunResult {
        let validation = await Task.detached(priority: .utility) {
            revalidate(plan.items)
        }.value
        await CleanupService.shared.recordRejectedItems(validation.rejectedItems, scope: .installers)
        let finalPlan = CleanupPlan(
            id: plan.cleanupPlan.id,
            createdAt: plan.cleanupPlan.createdAt,
            scope: plan.cleanupPlan.scope,
            candidates: plan.cleanupPlan.candidates.filter { validation.allowedPaths.contains($0.path) },
            rejectedItems: plan.cleanupPlan.rejectedItems + validation.rejectedItems
        )
        return await CleanupService.shared.execute(finalPlan)
    }

    private static func revalidate(_ items: [InstallerCleanupItem]) -> (
        allowedPaths: Set<String>,
        rejectedItems: [CleanupRejectedItem]
    ) {
        var allowedPaths: Set<String> = []
        var rejectedItems: [CleanupRejectedItem] = []
        for item in items {
            let url = URL(fileURLWithPath: item.path)
            if item.kind == .macOSApplication {
                guard let deviceID = item.filesystemDeviceID,
                      let fileID = item.filesystemFileID,
                      macOSInstallerIsEligible(
                          at: url,
                          expectedDeviceID: deviceID,
                          expectedFileID: fileID,
                          expectedModifiedDate: item.modifiedDate,
                          referenceDate: Date()
                      ) else {
                    rejectedItems.append(CleanupRejectedItem(path: item.path, reason: .changed))
                    continue
                }
                allowedPaths.insert(item.path)
                continue
            }
            guard let metadata = fileMetadata(at: url),
                  metadata.isRegularFile,
                  !metadata.isSymbolicLink,
                  metadata.sizeBytes == item.sizeBytes,
                  installerKind(for: url) == item.kind else {
                rejectedItems.append(CleanupRejectedItem(path: item.path, reason: .changed))
                continue
            }
            allowedPaths.insert(item.path)
        }
        return (allowedPaths, rejectedItems)
    }

    private static func scanSynchronously() -> ScanResult {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser.standardizedFileURL.path
        let roots = [
            SearchRoot(path: home + "/Downloads", source: .downloads),
            SearchRoot(path: home + "/Desktop", source: .desktop),
            SearchRoot(path: home + "/Documents", source: .documents),
            SearchRoot(path: home + "/Public", source: .publicFolder),
            SearchRoot(path: home + "/Library/Downloads", source: .library),
            SearchRoot(path: "/Users/Shared", source: .shared),
            SearchRoot(path: "/Users/Shared/Downloads", source: .shared),
            SearchRoot(path: home + "/Library/Caches/Homebrew", source: .homebrew),
            SearchRoot(
                path: home + "/Library/Mobile Documents/com~apple~CloudDocs/Downloads",
                source: .iCloud
            ),
            SearchRoot(
                path: home + "/Library/Containers/com.apple.mail/Data/Library/Mail Downloads",
                source: .mail
            ),
            SearchRoot(path: home + "/Library/Application Support/Telegram Desktop", source: .telegram),
            SearchRoot(path: home + "/Downloads/Telegram Desktop", source: .telegram)
        ]

        var itemsByPath: [String: InstallerCleanupItem] = [:]
        var unreadableItemCount = 0
        for root in roots {
            guard !Task.isCancelled else { return ScanResult(items: [], unreadableItemCount: 0) }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                continue
            }
            guard let enumerator = fileManager.enumerator(
                at: URL(fileURLWithPath: root.path, isDirectory: true),
                includingPropertiesForKeys: nil,
                options: [],
                errorHandler: { _, _ in
                    unreadableItemCount += 1
                    return true
                }
            ) else {
                unreadableItemCount += 1
                continue
            }

            let rootDepth = URL(fileURLWithPath: root.path).pathComponents.count
            while let url = enumerator.nextObject() as? URL {
                guard !Task.isCancelled else { return ScanResult(items: [], unreadableItemCount: 0) }
                let depth = url.pathComponents.count - rootDepth
                if depth > maximumScanDepth {
                    enumerator.skipDescendants()
                    continue
                }
                guard let metadata = fileMetadata(at: url) else {
                    unreadableItemCount += 1
                    continue
                }
                if metadata.isSymbolicLink {
                    if metadata.isDirectory { enumerator.skipDescendants() }
                    continue
                }
                guard metadata.isRegularFile,
                      let kind = installerKind(for: url),
                      kind != .zipArchive || isInstallerZip(url) else {
                    continue
                }

                let path = url.standardizedFileURL.path
                guard itemsByPath[path] == nil else { continue }
                let rawName = url.lastPathComponent
                let name = root.source == .homebrew ? homebrewDisplayName(rawName) : rawName
                itemsByPath[path] = InstallerCleanupItem(
                    path: path,
                    name: name,
                    source: root.source,
                    kind: kind,
                    sizeBytes: metadata.sizeBytes,
                    modifiedDate: metadata.modifiedDate,
                    filesystemDeviceID: nil,
                    filesystemFileID: nil
                )
            }
        }

        let macOSInstallers = scanMacOSInstallers(referenceDate: Date())
        unreadableItemCount += macOSInstallers.unreadableItemCount
        for item in macOSInstallers.items {
            itemsByPath[item.path] = item
        }

        let items = itemsByPath.values.sorted {
            if $0.source != $1.source {
                let lhs = InstallerSource.allCases.firstIndex(of: $0.source) ?? 0
                let rhs = InstallerSource.allCases.firstIndex(of: $1.source) ?? 0
                return lhs < rhs
            }
            if $0.sizeBytes != $1.sizeBytes { return $0.sizeBytes > $1.sizeBytes }
            return $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
        return ScanResult(items: items, unreadableItemCount: unreadableItemCount)
    }

    private static func scanMacOSInstallers(referenceDate: Date) -> ScanResult {
        guard softwareUpdateQueueIsExplicitlyEmpty() else {
            return ScanResult(items: [], unreadableItemCount: 0)
        }
        let applications = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: applications,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            return ScanResult(items: [], unreadableItemCount: 1)
        }

        var items: [InstallerCleanupItem] = []
        var unreadableItemCount = 0
        for url in urls where url.lastPathComponent.hasPrefix("Install macOS ") {
            guard !Task.isCancelled else { return ScanResult(items: [], unreadableItemCount: 0) }
            guard let identity = directoryIdentity(at: url) else {
                continue
            }
            guard macOSInstallerIsEligible(
                at: url,
                expectedDeviceID: identity.deviceID,
                expectedFileID: identity.fileID,
                expectedModifiedDate: identity.modifiedDate,
                referenceDate: referenceDate
            ) else {
                continue
            }
            guard let size = directoryAllocatedSize(at: url, timeout: macOSInstallerSizeTimeout) else {
                unreadableItemCount += 1
                continue
            }
            guard macOSInstallerIsEligible(
                at: url,
                expectedDeviceID: identity.deviceID,
                expectedFileID: identity.fileID,
                expectedModifiedDate: identity.modifiedDate,
                referenceDate: referenceDate
            ) else {
                continue
            }
            items.append(InstallerCleanupItem(
                path: url.standardizedFileURL.path,
                name: url.lastPathComponent,
                source: .applications,
                kind: .macOSApplication,
                sizeBytes: size,
                modifiedDate: identity.modifiedDate,
                filesystemDeviceID: identity.deviceID,
                filesystemFileID: identity.fileID
            ))
        }
        return ScanResult(items: items, unreadableItemCount: unreadableItemCount)
    }

    private static func macOSInstallerIsEligible(
        at url: URL,
        expectedDeviceID: UInt64,
        expectedFileID: UInt64,
        expectedModifiedDate: Date,
        referenceDate: Date
    ) -> Bool {
        let standardized = url.standardizedFileURL
        guard standardized.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
              standardized.lastPathComponent.hasPrefix("Install macOS "),
              pathsEqual(standardized.deletingLastPathComponent().path, "/Applications"),
              let identity = directoryIdentity(at: standardized),
              identity.deviceID == expectedDeviceID,
              identity.fileID == expectedFileID,
              identity.modifiedDate == expectedModifiedDate,
              referenceDate.timeIntervalSince(identity.modifiedDate) >= macOSInstallerMinimumAge,
              softwareUpdateQueueIsExplicitlyEmpty(),
              macOSInstallerProcessIsInactive(standardized.path),
              let installerMajorVersion = macOSInstallerMajorVersion(at: standardized),
              installerMajorVersion != ProcessInfo.processInfo.operatingSystemVersion.majorVersion else {
            return false
        }
        return true
    }

    private static func softwareUpdateQueueIsExplicitlyEmpty() -> Bool {
        let path = "/Library/Preferences/com.apple.SoftwareUpdate.plist"
        let executable = "/usr/bin/plutil"
        guard FileManager.default.fileExists(atPath: path),
              FileManager.default.isExecutableFile(atPath: executable) else {
            return false
        }
        let result = run(
            executable,
            arguments: ["-extract", "RecommendedUpdates", "json", "-o", "-", path],
            timeout: 5
        )
        return result.status == 0
            && !result.timedOut
            && result.output.filter { !$0.isWhitespace } == "[]"
    }

    private static func macOSInstallerMajorVersion(at url: URL) -> Int? {
        let plist = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist, options: .mappedIfSafe),
              let values = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ) as? [String: Any] else {
            return nil
        }
        let rawVersion: String?
        if let value = values["DTPlatformVersion"] as? String {
            rawVersion = value
        } else if let value = values["DTPlatformVersion"] as? NSNumber {
            rawVersion = value.stringValue
        } else {
            rawVersion = nil
        }
        return rawVersion.flatMap { Int($0.split(separator: ".").first ?? "") }
    }

    private static func macOSInstallerProcessIsInactive(_ path: String) -> Bool {
        let result = run("/usr/bin/pgrep", arguments: ["-f", path], timeout: 5)
        return !result.timedOut && result.status == 1
    }

    private static func directoryAllocatedSize(at root: URL, timeout: TimeInterval) -> UInt64? {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        guard let rootMetadata = allocatedMetadata(at: root) else { return nil }
        var total = rootMetadata.allocatedBytes
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
            return nil
        }
        while let url = enumerator.nextObject() as? URL {
            guard !Task.isCancelled,
                  ProcessInfo.processInfo.systemUptime < deadline,
                  let metadata = allocatedMetadata(at: url) else {
                return nil
            }
            if metadata.isSymbolicLink {
                enumerator.skipDescendants()
                continue
            }
            let (sum, overflow) = total.addingReportingOverflow(metadata.allocatedBytes)
            guard !overflow else { return nil }
            total = sum
        }
        return encounteredError ? nil : total
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

    private static func allocatedMetadata(at url: URL) -> (
        allocatedBytes: UInt64,
        isSymbolicLink: Bool
    )? {
        var value = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &value)
        }
        guard result == 0 else { return nil }
        let kind = value.st_mode & S_IFMT
        return (
            value.st_blocks > 0 ? UInt64(value.st_blocks) * 512 : 0,
            kind == S_IFLNK
        )
    }

    private static func run(
        _ executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) -> (status: Int32, output: String, timedOut: Bool) {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            return (-1, "", false)
        }
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
            return (-1, "", false)
        }
        let timeoutWork = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeoutWork.cancel()
        return (
            process.terminationStatus,
            String(decoding: data, as: UTF8.self),
            process.terminationReason == .uncaughtSignal && process.terminationStatus == SIGTERM
        )
    }

    private static func pathsEqual(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: [.caseInsensitive, .literal]) == .orderedSame
    }

    private static func installerKind(for url: URL) -> InstallerKind? {
        switch url.pathExtension.lowercased() {
        case "dmg": .diskImage
        case "pkg": .package
        case "mpkg": .metapackage
        case "iso": .opticalImage
        case "xip": .signedArchive
        case "zip": .zipArchive
        default: nil
        }
    }

    private static func isInstallerZip(_ url: URL) -> Bool {
        guard let executable = zipListExecutable() else { return false }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable.path)
        process.arguments = executable.arguments + [url.path]
        process.standardOutput = output
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
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        guard process.terminationStatus == 0 else { return false }

        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .prefix(maximumZipEntries)
            .contains { entry in
                let lowercased = entry.lowercased()
                return [".app", ".pkg", ".dmg", ".xip"].contains { suffix in
                    lowercased.hasSuffix(suffix) || lowercased.contains(suffix + "/")
                }
            }
    }

    private static func zipListExecutable() -> (path: String, arguments: [String])? {
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/zipinfo") {
            return ("/usr/bin/zipinfo", ["-1"])
        }
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/unzip") {
            return ("/usr/bin/unzip", ["-Z", "-1"])
        }
        return nil
    }

    private static func homebrewDisplayName(_ name: String) -> String {
        guard let separator = name.range(of: "--"),
              name[..<separator.lowerBound].count == 64,
              name[..<separator.lowerBound].allSatisfy({ $0.isHexDigit }) else {
            return name
        }
        return String(name[separator.upperBound...])
    }

    private static func fileMetadata(at url: URL) -> (
        sizeBytes: UInt64,
        modifiedDate: Date,
        isDirectory: Bool,
        isRegularFile: Bool,
        isSymbolicLink: Bool
    )? {
        var value = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &value)
        }
        guard result == 0 else { return nil }
        let kind = value.st_mode & S_IFMT
        return (
            value.st_size > 0 ? UInt64(value.st_size) : 0,
            Date(timeIntervalSince1970: TimeInterval(value.st_mtimespec.tv_sec)),
            kind == S_IFDIR,
            kind == S_IFREG,
            kind == S_IFLNK
        )
    }
}
