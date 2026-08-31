import Darwin
import Foundation

nonisolated struct TrashCleanupItem: Identifiable, Sendable {
    let path: String
    let sizeBytes: UInt64

    var id: String { path }
}

nonisolated struct TrashCleanupSnapshot: Sendable {
    let items: [TrashCleanupItem]
    let unreadableItemCount: Int
    let rootDevice: UInt64?
    let rootInode: UInt64?
}

nonisolated struct TrashCleanupPlan: Identifiable, Sendable {
    let cleanupPlan: CleanupPlan
    let rootDevice: UInt64
    let rootInode: UInt64

    var id: UUID { cleanupPlan.id }
}

nonisolated enum TrashCleanupService {
    static func scan() async -> TrashCleanupSnapshot {
        let root = trashRoot()
        guard let rootIdentity = directoryIdentity(at: root) else {
            return TrashCleanupSnapshot(
                items: [],
                unreadableItemCount: FileManager.default.fileExists(atPath: root) ? 1 : 0,
                rootDevice: nil,
                rootInode: nil
            )
        }

        var finalUpdate: DiskAnalysisUpdate?
        for await update in DiskAnalyzer.updates(for: root) {
            guard !Task.isCancelled else {
                return TrashCleanupSnapshot(
                    items: [], unreadableItemCount: 0,
                    rootDevice: rootIdentity.device, rootInode: rootIdentity.inode
                )
            }
            if update.isComplete { finalUpdate = update }
        }
        guard let finalUpdate else {
            return TrashCleanupSnapshot(
                items: [], unreadableItemCount: 1,
                rootDevice: rootIdentity.device, rootInode: rootIdentity.inode
            )
        }

        var items = finalUpdate.entrySizes.map {
            TrashCleanupItem(path: $0.key, sizeBytes: $0.value)
        }
        var unreadableItemCount = finalUpdate.unreadableItemCount
        if let urls = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: root, isDirectory: true),
            includingPropertiesForKeys: nil,
            options: []
        ) {
            let knownPaths = Set(items.map(\.path))
            for url in urls where !knownPaths.contains(url.standardizedFileURL.path) {
                if isSymbolicLink(at: url.path) {
                    items.append(TrashCleanupItem(path: url.standardizedFileURL.path, sizeBytes: 0))
                } else {
                    unreadableItemCount += 1
                }
            }
        }

        let eligiblePaths = await CleanupService.shared.eligiblePaths(items.map(\.path))
        items = items
            .filter { eligiblePaths.contains($0.path) }
            .sorted {
                if $0.sizeBytes != $1.sizeBytes { return $0.sizeBytes > $1.sizeBytes }
                return $0.path.localizedStandardCompare($1.path) == .orderedAscending
            }
        return TrashCleanupSnapshot(
            items: items,
            unreadableItemCount: unreadableItemCount,
            rootDevice: rootIdentity.device,
            rootInode: rootIdentity.inode
        )
    }

    static func previewCleanup(
        items: [TrashCleanupItem],
        rootDevice: UInt64,
        rootInode: UInt64
    ) async -> TrashCleanupPlan {
        let plan = await CleanupService.shared.preview(
            paths: items.map(\.path),
            scope: .trash
        )
        return TrashCleanupPlan(
            cleanupPlan: plan,
            rootDevice: rootDevice,
            rootInode: rootInode
        )
    }

    static func executeCleanup(_ plan: TrashCleanupPlan) async -> CleanupRunResult {
        await CleanupService.shared.permanentlyDeleteTrashItems(
            plan.cleanupPlan,
            trashRootDevice: plan.rootDevice,
            trashRootInode: plan.rootInode
        )
    }

    private static func trashRoot() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".Trash", isDirectory: true)
            .standardizedFileURL.path
    }

    private static func directoryIdentity(at path: String) -> (device: UInt64, inode: UInt64)? {
        var value = stat()
        guard path.withCString({ lstat($0, &value) }) == 0,
              value.st_mode & S_IFMT == S_IFDIR else {
            return nil
        }
        return (UInt64(value.st_dev), UInt64(value.st_ino))
    }

    private static func isSymbolicLink(at path: String) -> Bool {
        var value = stat()
        return path.withCString { lstat($0, &value) } == 0
            && value.st_mode & S_IFMT == S_IFLNK
    }
}
