import Darwin
import Foundation

nonisolated enum InstallerSource: String, CaseIterable, Sendable {
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
                    modifiedDate: metadata.modifiedDate
                )
            }
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
