import Darwin
import Foundation

nonisolated enum CacheCleanupCategory: String, CaseIterable, Sendable {
    case userCaches
    case userLogs
    case diagnosticReports
    case oldCrashReports
    case messagesPreviewCaches
    case utmCaches
    case savedApplicationState
    case recentItems
    case incompleteDownloads
    case oldMailAttachments
    case handoffClipboard
    case cachedDeviceFirmware

    var titleKey: String {
        switch self {
        case .userCaches: "User app caches"
        case .userLogs: "User app logs"
        case .diagnosticReports: "Diagnostic reports"
        case .oldCrashReports: "Old crash reports"
        case .messagesPreviewCaches: "Messages preview caches"
        case .utmCaches: "UTM sandbox caches"
        case .savedApplicationState: "Saved application states"
        case .recentItems: "Recent items"
        case .incompleteDownloads: "Incomplete downloads"
        case .oldMailAttachments: "Old Mail attachments"
        case .handoffClipboard: "Handoff clipboard cache"
        case .cachedDeviceFirmware: "Cached device firmware"
        }
    }
}

nonisolated struct CacheCleanupItem: Identifiable, Sendable {
    let path: String
    let category: CacheCleanupCategory
    let sizeBytes: UInt64

    var id: String { path }
}

nonisolated struct CacheCleanupSnapshot: Sendable {
    let items: [CacheCleanupItem]
    let scannedBytes: UInt64
    let unreadableItemCount: Int
}

nonisolated struct CacheCleanupPlan: Identifiable, Sendable {
    let cleanupPlan: CleanupPlan
    let items: [CacheCleanupItem]

    var id: UUID { cleanupPlan.id }
}

nonisolated enum CacheCleanupService {
    private struct Source: Sendable {
        let path: String
        let category: CacheCleanupCategory
    }

    static func scan() async -> CacheCleanupSnapshot {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let sources = [
            Source(path: home + "/Library/Caches", category: .userCaches),
            Source(path: home + "/Library/Logs", category: .userLogs),
            Source(path: home + "/Library/DiagnosticReports", category: .diagnosticReports),
            Source(path: home + "/Library/Saved Application State", category: .savedApplicationState)
        ]

        var discoveredItems: [CacheCleanupItem] = []
        var unreadableItemCount = 0

        for source in sources {
            guard !Task.isCancelled,
                  FileManager.default.fileExists(atPath: source.path) else {
                continue
            }

            var finalUpdate: DiskAnalysisUpdate?
            for await update in DiskAnalyzer.updates(for: source.path) {
                guard !Task.isCancelled else {
                    return CacheCleanupSnapshot(items: [], scannedBytes: 0, unreadableItemCount: 0)
                }
                if update.isComplete {
                    finalUpdate = update
                }
            }

            guard let finalUpdate else { continue }
            unreadableItemCount += finalUpdate.unreadableItemCount
            discoveredItems.append(contentsOf: finalUpdate.entrySizes.compactMap { path, size in
                let name = URL(fileURLWithPath: path).lastPathComponent
                guard size > 0, !name.hasPrefix(".") else { return nil }
                return CacheCleanupItem(path: path, category: source.category, sizeBytes: size)
            })
        }

        let utmIsSafe = await Task.detached(priority: .utility) {
            utmIsInactive()
        }.value
        if !utmIsSafe {
            discoveredItems.removeAll { item in
                item.category == .userCaches && pathsEqual(item.path, utmApplicationCacheRoot())
            }
        } else {
            let utmCaches = await scanUTMCaches()
            discoveredItems.append(contentsOf: utmCaches.items)
            unreadableItemCount += utmCaches.unreadableItemCount
        }

        let incompleteDownloads = await Task.detached(priority: .utility) {
            scanIncompleteDownloads()
        }.value
        discoveredItems.append(contentsOf: incompleteDownloads.items)
        unreadableItemCount += incompleteDownloads.unreadableItemCount

        let mailAttachments = await Task.detached(priority: .utility) {
            scanOldMailAttachments(referenceDate: Date())
        }.value
        discoveredItems.append(contentsOf: mailAttachments.items)
        unreadableItemCount += mailAttachments.unreadableItemCount

        let recentItems = await Task.detached(priority: .utility) {
            scanRecentItems()
        }.value
        discoveredItems.append(contentsOf: recentItems.items)
        unreadableItemCount += recentItems.unreadableItemCount

        let oldCrashReports = await Task.detached(priority: .utility) {
            scanOldCrashReports(referenceDate: Date())
        }.value
        discoveredItems.append(contentsOf: oldCrashReports.items)
        unreadableItemCount += oldCrashReports.unreadableItemCount

        let messagesPreviewCaches = await scanMessagesPreviewCaches()
        discoveredItems.append(contentsOf: messagesPreviewCaches.items)
        unreadableItemCount += messagesPreviewCaches.unreadableItemCount

        let handoffClipboard = await scanHandoffClipboard(referenceDate: Date())
        discoveredItems.append(contentsOf: handoffClipboard.items)
        unreadableItemCount += handoffClipboard.unreadableItemCount

        let cachedDeviceFirmware = await Task.detached(priority: .utility) {
            scanCachedDeviceFirmware()
        }.value
        discoveredItems.append(contentsOf: cachedDeviceFirmware.items)
        unreadableItemCount += cachedDeviceFirmware.unreadableItemCount

        let eligiblePaths = await CleanupService.shared.eligiblePaths(discoveredItems.map(\.path))
        let items = discoveredItems
            .filter { eligiblePaths.contains($0.path) }
            .sorted {
                if $0.category != $1.category {
                    let lhs = CacheCleanupCategory.allCases.firstIndex(of: $0.category) ?? 0
                    let rhs = CacheCleanupCategory.allCases.firstIndex(of: $1.category) ?? 0
                    return lhs < rhs
                }
                if $0.sizeBytes != $1.sizeBytes { return $0.sizeBytes > $1.sizeBytes }
                return $0.path.localizedStandardCompare($1.path) == .orderedAscending
            }
        let scannedBytes = items.reduce(UInt64(0)) { total, item in
            let (sum, overflow) = total.addingReportingOverflow(item.sizeBytes)
            return overflow ? UInt64.max : sum
        }

        return CacheCleanupSnapshot(
            items: items,
            scannedBytes: scannedBytes,
            unreadableItemCount: unreadableItemCount
        )
    }

    static func previewCleanup(items: [CacheCleanupItem]) async -> CacheCleanupPlan {
        let validation = await Task.detached(priority: .utility) {
            validateSpecialItems(items)
        }.value
        let basePlan = await CleanupService.shared.preview(
            paths: validation.items.map(\.path),
            scope: .cacheAndLogs
        )
        await CleanupService.shared.recordRejectedItems(
            validation.rejectedItems,
            scope: .cacheAndLogs
        )
        return CacheCleanupPlan(
            cleanupPlan: CleanupPlan(
                id: basePlan.id,
                createdAt: basePlan.createdAt,
                scope: basePlan.scope,
                candidates: basePlan.candidates,
                rejectedItems: basePlan.rejectedItems + validation.rejectedItems
            ),
            items: validation.items
        )
    }

    static func executeCleanup(_ plan: CacheCleanupPlan) async -> CleanupRunResult {
        let validation = await Task.detached(priority: .utility) {
            validateSpecialItems(plan.items)
        }.value
        await CleanupService.shared.recordRejectedItems(
            validation.rejectedItems,
            scope: .cacheAndLogs
        )
        let finalPlan = CleanupPlan(
            id: plan.cleanupPlan.id,
            createdAt: plan.cleanupPlan.createdAt,
            scope: plan.cleanupPlan.scope,
            candidates: plan.cleanupPlan.candidates.filter { validation.allowedPaths.contains($0.path) },
            rejectedItems: plan.cleanupPlan.rejectedItems + validation.rejectedItems
        )
        return await CleanupService.shared.execute(finalPlan)
    }

    private static func scanIncompleteDownloads() -> (
        items: [CacheCleanupItem],
        unreadableItemCount: Int
    ) {
        let downloads = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads", isDirectory: true)
        guard FileManager.default.fileExists(atPath: downloads.path) else {
            return ([], 0)
        }

        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: downloads,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            return ([], 1)
        }

        var items: [CacheCleanupItem] = []
        var unreadableItemCount = 0
        for url in urls where incompleteDownloadExtensions.contains(url.pathExtension.lowercased()) {
            guard !Task.isCancelled else { return ([], 0) }
            guard let size = incompleteDownloadSize(at: url.path) else {
                unreadableItemCount += 1
                continue
            }
            guard incompleteDownloadIsIdle(at: url.path) else { continue }
            items.append(CacheCleanupItem(
                path: url.standardizedFileURL.path,
                category: .incompleteDownloads,
                sizeBytes: size
            ))
        }
        return (items, unreadableItemCount)
    }

    private static func validateSpecialItems(_ items: [CacheCleanupItem]) -> (
        items: [CacheCleanupItem],
        allowedPaths: Set<String>,
        rejectedItems: [CleanupRejectedItem]
    ) {
        var validItems: [CacheCleanupItem] = []
        var rejectedItems: [CleanupRejectedItem] = []
        let requiresMailProbe = items.contains { $0.category == .oldMailAttachments }
        let mailIsSafe = !requiresMailProbe || mailIsInactive()
        let requiresUTMProbe = items.contains {
            $0.category == .utmCaches
                || ($0.category == .userCaches && pathsEqual($0.path, utmApplicationCacheRoot()))
        }
        let utmIsSafe = !requiresUTMProbe || utmIsInactive()
        for item in items {
            if item.category == .utmCaches
                || (item.category == .userCaches && pathsEqual(item.path, utmApplicationCacheRoot())) {
                guard utmIsSafe,
                      item.category == .userCaches || utmCacheItemIsAllowed(item.path) else {
                    rejectedItems.append(CleanupRejectedItem(path: item.path, reason: .changed))
                    continue
                }
                validItems.append(item)
                continue
            }
            if item.category == .messagesPreviewCaches {
                guard messagePreviewCacheItemIsAllowed(item.path) else {
                    rejectedItems.append(CleanupRejectedItem(path: item.path, reason: .changed))
                    continue
                }
                validItems.append(item)
                continue
            }
            if item.category == .oldCrashReports {
                guard oldCrashReportSize(at: item.path, referenceDate: Date()) == item.sizeBytes else {
                    rejectedItems.append(CleanupRejectedItem(path: item.path, reason: .changed))
                    continue
                }
                validItems.append(item)
                continue
            }
            if item.category == .cachedDeviceFirmware {
                guard cachedDeviceFirmwareSize(at: item.path) == item.sizeBytes else {
                    rejectedItems.append(CleanupRejectedItem(path: item.path, reason: .changed))
                    continue
                }
                validItems.append(item)
                continue
            }
            if item.category == .handoffClipboard {
                guard handoffItemIsStale(at: item.path, referenceDate: Date()) else {
                    rejectedItems.append(CleanupRejectedItem(path: item.path, reason: .changed))
                    continue
                }
                validItems.append(item)
                continue
            }
            if item.category == .recentItems {
                guard recentItemSize(at: item.path) == item.sizeBytes else {
                    rejectedItems.append(CleanupRejectedItem(path: item.path, reason: .changed))
                    continue
                }
                validItems.append(item)
                continue
            }
            if item.category == .oldMailAttachments {
                guard mailIsSafe,
                      mailAttachmentSize(at: item.path, referenceDate: Date()) == item.sizeBytes else {
                    rejectedItems.append(CleanupRejectedItem(path: item.path, reason: .changed))
                    continue
                }
                validItems.append(item)
                continue
            }
            guard item.category == .incompleteDownloads else {
                validItems.append(item)
                continue
            }
            guard incompleteDownloadSize(at: item.path) == item.sizeBytes,
                  incompleteDownloadIsIdle(at: item.path) else {
                rejectedItems.append(CleanupRejectedItem(path: item.path, reason: .changed))
                continue
            }
            validItems.append(item)
        }
        return (validItems, Set(validItems.map(\.path)), rejectedItems)
    }

    private static func scanUTMCaches() async -> (
        items: [CacheCleanupItem],
        unreadableItemCount: Int
    ) {
        var items: [CacheCleanupItem] = []
        var unreadableItemCount = 0
        for rootPath in utmSandboxCacheRoots() where isRealDirectory(at: rootPath) {
            var finalUpdate: DiskAnalysisUpdate?
            for await update in DiskAnalyzer.updates(for: rootPath) {
                guard !Task.isCancelled else { return ([], 0) }
                if update.isComplete { finalUpdate = update }
            }
            guard let finalUpdate else {
                unreadableItemCount += 1
                continue
            }
            unreadableItemCount += finalUpdate.unreadableItemCount
            items.append(contentsOf: finalUpdate.entrySizes.compactMap { path, size in
                let name = URL(fileURLWithPath: path).lastPathComponent
                guard !name.hasPrefix("."), utmCacheItemIsAllowed(path) else { return nil }
                return CacheCleanupItem(path: path, category: .utmCaches, sizeBytes: size)
            })
        }
        return (items, unreadableItemCount)
    }

    private static func utmCacheItemIsAllowed(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard !url.lastPathComponent.hasPrefix("."),
              !isSymbolicLink(at: url.path) else {
            return false
        }
        return utmSandboxCacheRoots().contains { root in
            isRealDirectory(at: root)
                && pathsEqual(url.deletingLastPathComponent().path, root)
        }
    }

    private static func utmSandboxCacheRoots() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let container = home + "/Library/Containers/com.utmapp.UTM/Data"
        return [
            container + "/Library/Caches",
            container + "/tmp"
        ]
    }

    private static func utmApplicationCacheRoot() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches", isDirectory: true)
            .appendingPathComponent("com.utmapp.UTM", isDirectory: true)
            .standardizedFileURL.path
    }

    private static func utmIsInactive() -> Bool {
        let executable = "/usr/bin/pgrep"
        guard FileManager.default.isExecutableFile(atPath: executable) else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-x", "UTM"]
        process.standardOutput = FileHandle.nullDevice
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
        process.waitUntilExit()
        timeout.cancel()
        return process.terminationStatus == 1
    }

    private static func scanMessagesPreviewCaches() async -> (
        items: [CacheCleanupItem],
        unreadableItemCount: Int
    ) {
        var items: [CacheCleanupItem] = []
        var unreadableItemCount = 0
        for rootPath in messagesPreviewCacheRoots() where isRealDirectory(at: rootPath) {
            var finalUpdate: DiskAnalysisUpdate?
            for await update in DiskAnalyzer.updates(for: rootPath) {
                guard !Task.isCancelled else { return ([], 0) }
                if update.isComplete { finalUpdate = update }
            }
            guard let finalUpdate else {
                unreadableItemCount += 1
                continue
            }
            unreadableItemCount += finalUpdate.unreadableItemCount
            items.append(contentsOf: finalUpdate.entrySizes.compactMap { path, size in
                let name = URL(fileURLWithPath: path).lastPathComponent
                guard !name.hasPrefix("."), messagePreviewCacheItemIsAllowed(path) else {
                    return nil
                }
                return CacheCleanupItem(
                    path: path,
                    category: .messagesPreviewCaches,
                    sizeBytes: size
                )
            })
        }
        return (items, unreadableItemCount)
    }

    private static func messagePreviewCacheItemIsAllowed(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard !url.lastPathComponent.hasPrefix("."),
              !isSymbolicLink(at: url.path) else {
            return false
        }
        return messagesPreviewCacheRoots().contains { root in
            isRealDirectory(at: root)
                && pathsEqual(url.deletingLastPathComponent().path, root)
        }
    }

    private static func messagesPreviewCacheRoots() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        return [
            home + "/Library/Messages/StickerCache",
            home + "/Library/Messages/Caches/Previews/Attachments",
            home + "/Library/Messages/Caches/Previews/StickerCache"
        ]
    }

    private static func scanOldCrashReports(referenceDate: Date) -> (
        items: [CacheCleanupItem],
        unreadableItemCount: Int
    ) {
        let rootPath = crashReporterRoot()
        guard isRealDirectory(at: rootPath) else {
            return ([], FileManager.default.fileExists(atPath: rootPath) ? 1 : 0)
        }

        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        var unreadableItemCount = 0
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey
            ],
            options: [],
            errorHandler: { _, _ in
                unreadableItemCount += 1
                return true
            }
        ) else {
            return ([], 1)
        }

        var items: [CacheCleanupItem] = []
        for case let url as URL in enumerator {
            guard !Task.isCancelled else { return ([], 0) }
            do {
                let values = try url.resourceValues(forKeys: [
                    .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey
                ])
                if values.isSymbolicLink == true {
                    if values.isDirectory == true { enumerator.skipDescendants() }
                    continue
                }
                guard values.isRegularFile == true,
                      let size = oldCrashReportSize(at: url.path, referenceDate: referenceDate) else {
                    continue
                }
                items.append(CacheCleanupItem(
                    path: url.standardizedFileURL.path,
                    category: .oldCrashReports,
                    sizeBytes: size
                ))
            } catch {
                unreadableItemCount += 1
                enumerator.skipDescendants()
            }
        }
        return (items, unreadableItemCount)
    }

    private static func oldCrashReportSize(at path: String, referenceDate: Date) -> UInt64? {
        let root = crashReporterRoot()
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let canonicalPath = url.resolvingSymlinksInPath().standardizedFileURL.path
        let canonicalRoot = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL.path
        guard isRealDirectory(at: root),
              pathIsInside(url.path, root: root),
              pathIsInside(canonicalPath, root: canonicalRoot),
              let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate,
              modified < referenceDate.addingTimeInterval(-crashReportMinimumAge) else {
            return nil
        }
        var value = stat()
        guard url.path.withCString({ lstat($0, &value) }) == 0,
              value.st_mode & S_IFMT == S_IFREG,
              value.st_blocks >= 0 else {
            return nil
        }
        return UInt64(value.st_blocks) * 512
    }

    private static func crashReporterRoot() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("CrashReporter", isDirectory: true)
            .standardizedFileURL.path
    }

    private static func scanCachedDeviceFirmware() -> (
        items: [CacheCleanupItem],
        unreadableItemCount: Int
    ) {
        var items: [CacheCleanupItem] = []
        var unreadableItemCount = 0

        for rootPath in shallowFirmwareRoots() where isRealDirectory(at: rootPath) {
            let root = URL(fileURLWithPath: rootPath, isDirectory: true)
            let urls: [URL]
            do {
                urls = try FileManager.default.contentsOfDirectory(
                    at: root,
                    includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                )
            } catch {
                unreadableItemCount += 1
                continue
            }
            for url in urls where url.pathExtension == "ipsw" {
                guard !Task.isCancelled else { return ([], 0) }
                guard let size = cachedDeviceFirmwareSize(at: url.path) else {
                    unreadableItemCount += 1
                    continue
                }
                items.append(CacheCleanupItem(
                    path: url.standardizedFileURL.path,
                    category: .cachedDeviceFirmware,
                    sizeBytes: size
                ))
            }
        }

        for rootPath in configuratorFirmwareRoots() {
            let root = URL(fileURLWithPath: rootPath, isDirectory: true)
            var rootUnreadableCount = 0
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
                options: [],
                errorHandler: { _, _ in
                    rootUnreadableCount += 1
                    return true
                }
            ) else {
                unreadableItemCount += 1
                continue
            }
            for case let url as URL in enumerator {
                guard !Task.isCancelled else { return ([], 0) }
                do {
                    let values = try url.resourceValues(forKeys: [
                        .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey
                    ])
                    if values.isSymbolicLink == true {
                        if values.isDirectory == true { enumerator.skipDescendants() }
                        continue
                    }
                    guard values.isRegularFile == true, url.pathExtension == "ipsw" else { continue }
                    guard let size = cachedDeviceFirmwareSize(at: url.path) else {
                        rootUnreadableCount += 1
                        continue
                    }
                    items.append(CacheCleanupItem(
                        path: url.standardizedFileURL.path,
                        category: .cachedDeviceFirmware,
                        sizeBytes: size
                    ))
                } catch {
                    rootUnreadableCount += 1
                    enumerator.skipDescendants()
                }
            }
            unreadableItemCount += rootUnreadableCount
        }

        return (items, unreadableItemCount)
    }

    private static func cachedDeviceFirmwareSize(at path: String) -> UInt64? {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.pathExtension == "ipsw",
              firmwarePathIsAllowed(url.path) else {
            return nil
        }
        var value = stat()
        guard url.path.withCString({ lstat($0, &value) }) == 0,
              value.st_mode & S_IFMT == S_IFREG,
              value.st_blocks >= 0 else {
            return nil
        }
        return UInt64(value.st_blocks) * 512
    }

    private static func firmwarePathIsAllowed(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        if shallowFirmwareRoots().contains(where: { root in
            isRealDirectory(at: root) && pathsEqual(url.deletingLastPathComponent().path, root)
        }) {
            return true
        }

        let canonicalPath = url.resolvingSymlinksInPath().standardizedFileURL.path
        return configuratorFirmwareRoots().contains { root in
            let canonicalRoot = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL.path
            return pathIsInside(url.path, root: root)
                && pathIsInside(canonicalPath, root: canonicalRoot)
                && !pathsEqual(canonicalPath, canonicalRoot)
        }
    }

    private static func shallowFirmwareRoots() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        return [
            home + "/Library/iTunes/iPhone Software Updates",
            home + "/Library/iTunes/iPad Software Updates",
            home + "/Library/iTunes/iPod Software Updates"
        ]
    }

    private static func configuratorFirmwareRoots() -> [String] {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers", isDirectory: true)
            .standardizedFileURL
        guard isRealDirectory(at: root.path),
              let urls = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
              ) else {
            return []
        }
        return urls.compactMap { url in
            guard url.lastPathComponent.hasSuffix(".group.com.apple.configurator"),
                  isRealDirectory(at: url.path) else {
                return nil
            }
            return url.standardizedFileURL.path
        }
    }

    private static func pathIsInside(_ path: String, root: String) -> Bool {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        let normalizedRoot = URL(fileURLWithPath: root).standardizedFileURL.path
        return normalized.lowercased().hasPrefix(normalizedRoot.lowercased() + "/")
    }

    private static func pathsEqual(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: [.caseInsensitive, .literal]) == .orderedSame
    }

    private static func scanHandoffClipboard(referenceDate: Date) async -> (
        items: [CacheCleanupItem],
        unreadableItemCount: Int
    ) {
        let root = handoffClipboardRoot()
        guard isRealDirectory(at: root) else {
            return ([], FileManager.default.fileExists(atPath: root) ? 1 : 0)
        }

        var finalUpdate: DiskAnalysisUpdate?
        for await update in DiskAnalyzer.updates(for: root) {
            guard !Task.isCancelled else { return ([], 0) }
            if update.isComplete { finalUpdate = update }
        }
        guard let finalUpdate else { return ([], 1) }

        var unreadableItemCount = finalUpdate.unreadableItemCount
        let items = finalUpdate.entrySizes.compactMap { path, size -> CacheCleanupItem? in
            guard handoffItemIsStale(at: path, referenceDate: referenceDate) else {
                if FileManager.default.fileExists(atPath: path) {
                    let url = URL(fileURLWithPath: path)
                    if (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate == nil {
                        unreadableItemCount += 1
                    }
                }
                return nil
            }
            return CacheCleanupItem(
                path: path,
                category: .handoffClipboard,
                sizeBytes: size
            )
        }
        return (items, unreadableItemCount)
    }

    private static func handoffItemIsStale(at path: String, referenceDate: Date) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let root = handoffClipboardRoot()
        guard isRealDirectory(at: root),
              url.deletingLastPathComponent().path.compare(
                root,
                options: [.caseInsensitive, .literal]
              ) == .orderedSame,
              !isSymbolicLink(at: url.path),
              let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate,
              modified < referenceDate.addingTimeInterval(-handoffMinimumAge) else {
            return false
        }
        return true
    }

    private static func handoffClipboardRoot() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers", isDirectory: true)
            .appendingPathComponent("group.com.apple.coreservices.useractivityd", isDirectory: true)
            .appendingPathComponent("shared-pasteboard", isDirectory: true)
            .standardizedFileURL.path
    }

    private static func isRealDirectory(at path: String) -> Bool {
        var value = stat()
        return path.withCString { lstat($0, &value) } == 0
            && value.st_mode & S_IFMT == S_IFDIR
    }

    private static func isSymbolicLink(at path: String) -> Bool {
        var value = stat()
        return path.withCString { lstat($0, &value) } == 0
            && value.st_mode & S_IFMT == S_IFLNK
    }

    private static func scanRecentItems() -> (
        items: [CacheCleanupItem],
        unreadableItemCount: Int
    ) {
        var items: [CacheCleanupItem] = []
        var unreadableItemCount = 0
        for path in recentItemPaths() where FileManager.default.fileExists(atPath: path) {
            guard let size = recentItemSize(at: path) else {
                unreadableItemCount += 1
                continue
            }
            items.append(CacheCleanupItem(
                path: path,
                category: .recentItems,
                sizeBytes: size
            ))
        }
        return (items, unreadableItemCount)
    }

    private static func recentItemSize(at path: String) -> UInt64? {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard recentItemPaths().contains(where: { candidate in
            normalized.compare(candidate, options: [.caseInsensitive, .literal]) == .orderedSame
        }) else {
            return nil
        }
        var value = stat()
        guard normalized.withCString({ lstat($0, &value) }) == 0,
              value.st_mode & S_IFMT == S_IFREG else {
            return nil
        }
        return value.st_blocks > 0 ? UInt64(value.st_blocks) * 512 : 0
    }

    private static func recentItemPaths() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let shared = home + "/Library/Application Support/com.apple.sharedfilelist"
        return [
            shared + "/com.apple.LSSharedFileList.RecentApplications.sfl2",
            shared + "/com.apple.LSSharedFileList.RecentDocuments.sfl2",
            shared + "/com.apple.LSSharedFileList.RecentServers.sfl2",
            shared + "/com.apple.LSSharedFileList.RecentHosts.sfl2",
            shared + "/com.apple.LSSharedFileList.RecentApplications.sfl",
            shared + "/com.apple.LSSharedFileList.RecentDocuments.sfl",
            shared + "/com.apple.LSSharedFileList.RecentServers.sfl",
            shared + "/com.apple.LSSharedFileList.RecentHosts.sfl",
            home + "/Library/Preferences/com.apple.recentitems.plist"
        ]
    }

    private static func scanOldMailAttachments(referenceDate: Date) -> (
        items: [CacheCleanupItem],
        unreadableItemCount: Int
    ) {
        guard mailIsInactive() else { return ([], 0) }
        var items: [CacheCleanupItem] = []
        var unreadableItemCount = 0

        for rootPath in mailDownloadRoots() {
            let root = URL(fileURLWithPath: rootPath, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: rootPath, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                continue
            }

            var rootUnreadableCount = 0
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [
                    .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                    .fileSizeKey, .contentModificationDateKey
                ],
                options: [],
                errorHandler: { _, _ in
                    rootUnreadableCount += 1
                    return true
                }
            ) else {
                unreadableItemCount += 1
                continue
            }

            var rootBytes: UInt64 = 0
            var rootItems: [CacheCleanupItem] = []
            for case let url as URL in enumerator {
                guard !Task.isCancelled else { return ([], 0) }
                do {
                    let values = try url.resourceValues(forKeys: [
                        .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                        .fileSizeKey, .contentModificationDateKey
                    ])
                    if values.isSymbolicLink == true {
                        if values.isDirectory == true { enumerator.skipDescendants() }
                        continue
                    }
                    guard values.isRegularFile == true else { continue }
                    let size = UInt64(max(0, values.fileSize ?? 0))
                    let (sum, overflow) = rootBytes.addingReportingOverflow(size)
                    rootBytes = overflow ? UInt64.max : sum
                    if let modified = values.contentModificationDate,
                       modified < referenceDate.addingTimeInterval(-mailAttachmentMinimumAge) {
                        rootItems.append(CacheCleanupItem(
                            path: url.standardizedFileURL.path,
                            category: .oldMailAttachments,
                            sizeBytes: size
                        ))
                    }
                } catch {
                    rootUnreadableCount += 1
                    enumerator.skipDescendants()
                }
            }

            unreadableItemCount += rootUnreadableCount
            guard rootUnreadableCount == 0,
                  rootBytes >= mailDownloadsMinimumBytes else {
                continue
            }
            items.append(contentsOf: rootItems)
        }
        return (items, unreadableItemCount)
    }

    private static func mailAttachmentSize(at path: String, referenceDate: Date) -> UInt64? {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard mailDownloadRoots().contains(where: { root in
            url.path.lowercased().hasPrefix(root.lowercased() + "/")
        }) else {
            return nil
        }
        do {
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey
            ])
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let modified = values.contentModificationDate,
                  modified < referenceDate.addingTimeInterval(-mailAttachmentMinimumAge) else {
                return nil
            }
            return UInt64(max(0, values.fileSize ?? 0))
        } catch {
            return nil
        }
    }

    private static func mailIsInactive() -> Bool {
        let executable = "/usr/bin/pgrep"
        guard FileManager.default.isExecutableFile(atPath: executable) else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-x", "Mail"]
        process.standardOutput = FileHandle.nullDevice
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
        process.waitUntilExit()
        timeout.cancel()
        return process.terminationStatus == 1
    }

    private static func mailDownloadRoots() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        return [
            home + "/Library/Mail Downloads",
            home + "/Library/Containers/com.apple.mail/Data/Library/Mail Downloads"
        ]
    }

    private static func incompleteDownloadSize(at path: String) -> UInt64? {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let downloads = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads", isDirectory: true)
            .standardizedFileURL.path
        guard url.deletingLastPathComponent().path.compare(
            downloads,
            options: [.caseInsensitive, .literal]
        ) == .orderedSame,
            incompleteDownloadExtensions.contains(url.pathExtension.lowercased()) else {
            return nil
        }
        do {
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey
            ])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
            return UInt64(max(0, values.fileSize ?? 0))
        } catch {
            return nil
        }
    }

    private static func incompleteDownloadIsIdle(at path: String) -> Bool {
        let executable = "/usr/sbin/lsof"
        guard FileManager.default.isExecutableFile(atPath: executable) else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = [path]
        process.standardOutput = FileHandle.nullDevice
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
        process.waitUntilExit()
        timeout.cancel()
        return process.terminationStatus == 1
    }

    private static let incompleteDownloadExtensions: Set<String> = [
        "download", "crdownload", "part"
    ]
    private static let mailAttachmentMinimumAge: TimeInterval = 30 * 24 * 60 * 60
    private static let mailDownloadsMinimumBytes: UInt64 = 5 * 1024 * 1024
    private static let handoffMinimumAge: TimeInterval = 60 * 60
    private static let crashReportMinimumAge: TimeInterval = 30 * 24 * 60 * 60
}
