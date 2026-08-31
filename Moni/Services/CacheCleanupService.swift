import Darwin
import Foundation

nonisolated enum CacheCleanupCategory: String, CaseIterable, Sendable {
    case userCaches
    case userLogs
    case diagnosticReports
    case savedApplicationState
    case incompleteDownloads

    var titleKey: String {
        switch self {
        case .userCaches: "User app caches"
        case .userLogs: "User app logs"
        case .diagnosticReports: "Diagnostic reports"
        case .savedApplicationState: "Saved application states"
        case .incompleteDownloads: "Incomplete downloads"
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

        let incompleteDownloads = await Task.detached(priority: .utility) {
            scanIncompleteDownloads()
        }.value
        discoveredItems.append(contentsOf: incompleteDownloads.items)
        unreadableItemCount += incompleteDownloads.unreadableItemCount

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
        for item in items {
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
}
