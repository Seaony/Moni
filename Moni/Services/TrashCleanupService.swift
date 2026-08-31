import Darwin
import Foundation

nonisolated struct TrashCleanupItem: Identifiable, Sendable {
    let path: String
    let trashRootPath: String
    let locationName: String
    let sizeBytes: UInt64

    var id: String { path }
}

nonisolated struct TrashCleanupRootIdentity: Sendable {
    let path: String
    let locationName: String
    let device: UInt64
    let inode: UInt64
}

nonisolated struct TrashCleanupSnapshot: Sendable {
    let items: [TrashCleanupItem]
    let unreadableItemCount: Int
    let rootIdentities: [TrashCleanupRootIdentity]
}

nonisolated struct TrashCleanupPlan: Identifiable, Sendable {
    let cleanupPlan: CleanupPlan
    let rootIdentities: [TrashCleanupRootIdentity]

    var id: UUID { cleanupPlan.id }
}

nonisolated enum TrashCleanupService {
    static func scan() async -> TrashCleanupSnapshot {
        let roots = trashRoots()
        var items: [TrashCleanupItem] = []
        var unreadableItemCount = 0
        for root in roots {
            guard !Task.isCancelled else {
                return TrashCleanupSnapshot(items: [], unreadableItemCount: 0, rootIdentities: roots)
            }
            let result = await scan(root: root)
            items.append(contentsOf: result.items)
            unreadableItemCount += result.unreadableItemCount
        }

        let eligiblePaths = await CleanupService.shared.eligiblePaths(items.map(\.path))
        items = items
            .filter { eligiblePaths.contains($0.path) }
            .sorted {
                if $0.trashRootPath != $1.trashRootPath {
                    return $0.locationName.localizedStandardCompare($1.locationName) == .orderedAscending
                }
                if $0.sizeBytes != $1.sizeBytes { return $0.sizeBytes > $1.sizeBytes }
                return $0.path.localizedStandardCompare($1.path) == .orderedAscending
            }
        return TrashCleanupSnapshot(
            items: items,
            unreadableItemCount: unreadableItemCount,
            rootIdentities: roots
        )
    }

    static func previewCleanup(
        items: [TrashCleanupItem],
        rootIdentities: [TrashCleanupRootIdentity]
    ) async -> TrashCleanupPlan {
        let currentRoots: [String: TrashCleanupRootIdentity] = Dictionary(
            uniqueKeysWithValues: rootIdentities.compactMap { root -> (String, TrashCleanupRootIdentity)? in
                guard let current = directoryIdentity(at: root.path),
                      current.device == root.device,
                      current.inode == root.inode else {
                    return nil
                }
                return (root.path, root)
            }
        )
        let validItems = items.filter { item in
            currentRoots[item.trashRootPath] != nil
                && pathsEqual(
                    URL(fileURLWithPath: item.path).deletingLastPathComponent().path,
                    item.trashRootPath
                )
        }
        let plan = await CleanupService.shared.preview(
            paths: validItems.map(\.path),
            scope: .trash
        )
        return TrashCleanupPlan(
            cleanupPlan: plan,
            rootIdentities: Array(currentRoots.values)
        )
    }

    static func executeCleanup(_ plan: TrashCleanupPlan) async -> CleanupRunResult {
        await CleanupService.shared.permanentlyDeleteTrashItems(
            plan.cleanupPlan,
            trashRoots: plan.rootIdentities
        )
    }

    private static func scan(root: TrashCleanupRootIdentity) async -> (
        items: [TrashCleanupItem],
        unreadableItemCount: Int
    ) {
        var finalUpdate: DiskAnalysisUpdate?
        for await update in DiskAnalyzer.updates(for: root.path) {
            guard !Task.isCancelled else { return ([], 0) }
            if update.isComplete { finalUpdate = update }
        }
        guard let finalUpdate else { return ([], 1) }

        var items = finalUpdate.entrySizes.map {
            TrashCleanupItem(
                path: $0.key,
                trashRootPath: root.path,
                locationName: root.locationName,
                sizeBytes: $0.value
            )
        }
        var unreadableItemCount = finalUpdate.unreadableItemCount
        if let urls = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: root.path, isDirectory: true),
            includingPropertiesForKeys: nil,
            options: []
        ) {
            let knownPaths = Set(items.map(\.path))
            for url in urls where !knownPaths.contains(url.standardizedFileURL.path) {
                if isSymbolicLink(at: url.path) {
                    items.append(TrashCleanupItem(
                        path: url.standardizedFileURL.path,
                        trashRootPath: root.path,
                        locationName: root.locationName,
                        sizeBytes: 0
                    ))
                } else {
                    unreadableItemCount += 1
                }
            }
        } else {
            unreadableItemCount += 1
        }
        if !pathsEqual(root.path, trashRoot()), unreadableItemCount > 0 {
            return ([], unreadableItemCount)
        }
        return (items, unreadableItemCount)
    }

    private static func trashRoots() -> [TrashCleanupRootIdentity] {
        var candidates = [(path: trashRoot(), locationName: "Current user Trash")]
        candidates.append(contentsOf: externalWritableVolumes().map { volume in
            (
                volume.appendingPathComponent(".Trashes", isDirectory: true).standardizedFileURL.path,
                "\(volume.lastPathComponent) Trash"
            )
        })
        return candidates.compactMap { candidate in
            guard let identity = directoryIdentity(at: candidate.path) else { return nil }
            return TrashCleanupRootIdentity(
                path: candidate.path,
                locationName: candidate.locationName,
                device: identity.device,
                inode: identity.inode
            )
        }
    }

    private static func externalWritableVolumes() -> [URL] {
        let keys: Set<URLResourceKey> = [
            .volumeIsInternalKey, .volumeIsLocalKey, .volumeIsReadOnlyKey
        ]
        return (FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(keys),
            options: [.skipHiddenVolumes]
        ) ?? []).compactMap { volume in
            let standardized = volume.standardizedFileURL
            guard pathsEqual(standardized.deletingLastPathComponent().path, "/Volumes"),
                  directoryIdentity(at: standardized.path) != nil,
                  let values = try? standardized.resourceValues(forKeys: keys),
                  values.volumeIsInternal == false,
                  values.volumeIsLocal == true,
                  values.volumeIsReadOnly == false else {
                return nil
            }
            return standardized
        }
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

    private static func pathsEqual(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: [.caseInsensitive, .literal]) == .orderedSame
    }
}
