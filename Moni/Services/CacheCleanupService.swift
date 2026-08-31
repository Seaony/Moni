import Foundation

nonisolated enum CacheCleanupCategory: String, CaseIterable, Sendable {
    case userCaches
    case userLogs
    case diagnosticReports
    case savedApplicationState

    var titleKey: String {
        switch self {
        case .userCaches: "User app caches"
        case .userLogs: "User app logs"
        case .diagnosticReports: "Diagnostic reports"
        case .savedApplicationState: "Saved application states"
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
}
