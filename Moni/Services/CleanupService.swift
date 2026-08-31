import Darwin
import Foundation

nonisolated enum CleanupScope: String, Codable, Sendable {
    case diskBrowser
    case cacheAndLogs
    case caches
    case logs
    case projects
    case installers
    case trash
    case applications
    case maintenance
}

nonisolated enum CleanupRejection: String, Codable, Error, Sendable {
    case invalidPath
    case missing
    case protected
    case whitelisted
    case changed
    case expired
}

nonisolated struct CleanupRejectedItem: Identifiable, Sendable {
    let path: String
    let reason: CleanupRejection

    var id: String { path }
}

nonisolated struct CleanupCandidate: Identifiable, Sendable {
    let path: String
    let canonicalPath: String
    let device: UInt64
    let inode: UInt64

    var id: String { path }
}

nonisolated struct CleanupPlan: Identifiable, Sendable {
    let id: UUID
    let createdAt: Date
    let scope: CleanupScope
    let candidates: [CleanupCandidate]
    let rejectedItems: [CleanupRejectedItem]
}

nonisolated struct CleanupRunResult: Sendable {
    let trashedPaths: [String]
    let rejectedItems: [CleanupRejectedItem]
    let failedPaths: [String]
}

nonisolated enum CleanupOperationAction: String, Codable, Sendable {
    case previewed
    case trashed
    case deleted
    case skipped
    case failed
}

nonisolated struct CleanupOperationRecord: Codable, Identifiable, Sendable {
    let id: UUID
    let date: Date
    let scope: CleanupScope
    let action: CleanupOperationAction
    let path: String
    let detail: String?
}

nonisolated enum CleanupPreferences {
    static func whitelist() -> [String] {
        (UserDefaults.standard.stringArray(forKey: PreferenceKey.cleanupWhitelist) ?? [])
            .map(normalizedPath)
            .filter { !$0.isEmpty }
            .uniqued()
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static func addToWhitelist(_ paths: [String]) {
        let merged = whitelist() + paths.map(normalizedPath)
        UserDefaults.standard.set(merged.filter { !$0.isEmpty }.uniqued(), forKey: PreferenceKey.cleanupWhitelist)
    }

    static func removeFromWhitelist(_ path: String) {
        let normalized = normalizedPath(path)
        UserDefaults.standard.set(
            whitelist().filter { normalizedPath($0) != normalized },
            forKey: PreferenceKey.cleanupWhitelist
        )
    }

    static func isWhitelisted(_ path: String) -> Bool {
        let normalized = normalizedPath(path)
        return whitelist().contains { protectedPath in
            let protected = normalizedPath(protectedPath)
            return normalized == protected
                || normalized.hasPrefix(protected + "/")
                || protected.hasPrefix(normalized + "/")
        }
    }

    private static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}

actor CleanupService {
    static let shared = CleanupService()

    private let fileManager = FileManager.default
    private let maximumHistoryCount = 500
    private let planLifetime: TimeInterval = 5 * 60

    func preview(
        paths: [String],
        scope: CleanupScope,
        whitelist: [String] = CleanupPreferences.whitelist()
    ) -> CleanupPlan {
        var candidates: [CleanupCandidate] = []
        var rejectedItems: [CleanupRejectedItem] = []
        var seenCanonicalPaths: Set<String> = []

        for path in paths {
            switch validate(path: path, whitelist: whitelist) {
            case let .success(candidate):
                guard seenCanonicalPaths.insert(candidate.canonicalPath).inserted else { continue }
                candidates.append(candidate)
            case let .failure(reason):
                rejectedItems.append(CleanupRejectedItem(path: path, reason: reason))
            }
        }

        candidates.sort {
            let lhsDepth = $0.canonicalPath.split(separator: "/").count
            let rhsDepth = $1.canonicalPath.split(separator: "/").count
            if lhsDepth != rhsDepth { return lhsDepth < rhsDepth }
            return $0.canonicalPath.localizedStandardCompare($1.canonicalPath) == .orderedAscending
        }
        candidates = candidates.reduce(into: []) { result, candidate in
            guard !result.contains(where: { pathIsInside(candidate.canonicalPath, root: $0.canonicalPath) }) else {
                return
            }
            result.append(candidate)
        }

        let plan = CleanupPlan(
            id: UUID(),
            createdAt: Date(),
            scope: scope,
            candidates: candidates,
            rejectedItems: rejectedItems
        )
        appendHistory(
            candidates.map {
                historyRecord(scope: scope, action: .previewed, path: $0.path, detail: nil)
            } + rejectedItems.map {
                historyRecord(scope: scope, action: .skipped, path: $0.path, detail: $0.reason.rawValue)
            }
        )
        return plan
    }

    func execute(
        _ plan: CleanupPlan,
        whitelist: [String] = CleanupPreferences.whitelist()
    ) -> CleanupRunResult {
        guard Date().timeIntervalSince(plan.createdAt) <= planLifetime else {
            let rejected = plan.candidates.map {
                CleanupRejectedItem(path: $0.path, reason: .expired)
            }
            appendHistory(rejected.map {
                historyRecord(scope: plan.scope, action: .skipped, path: $0.path, detail: $0.reason.rawValue)
            })
            return CleanupRunResult(trashedPaths: [], rejectedItems: rejected, failedPaths: [])
        }

        var trashedPaths: [String] = []
        var rejectedItems = plan.rejectedItems
        var failedPaths: [String] = []
        var records: [CleanupOperationRecord] = []

        for plannedCandidate in plan.candidates {
            switch validate(path: plannedCandidate.path, whitelist: whitelist) {
            case let .failure(reason):
                let rejected = CleanupRejectedItem(path: plannedCandidate.path, reason: reason)
                rejectedItems.append(rejected)
                records.append(historyRecord(scope: plan.scope, action: .skipped, path: rejected.path, detail: reason.rawValue))
            case let .success(currentCandidate):
                guard currentCandidate.device == plannedCandidate.device,
                      currentCandidate.inode == plannedCandidate.inode else {
                    let rejected = CleanupRejectedItem(path: plannedCandidate.path, reason: .changed)
                    rejectedItems.append(rejected)
                    records.append(historyRecord(
                        scope: plan.scope,
                        action: .skipped,
                        path: rejected.path,
                        detail: CleanupRejection.changed.rawValue
                    ))
                    continue
                }
                do {
                    try fileManager.trashItem(
                        at: URL(fileURLWithPath: currentCandidate.path),
                        resultingItemURL: nil
                    )
                    trashedPaths.append(currentCandidate.path)
                    records.append(historyRecord(
                        scope: plan.scope,
                        action: .trashed,
                        path: currentCandidate.path,
                        detail: nil
                    ))
                } catch {
                    failedPaths.append(currentCandidate.path)
                    records.append(historyRecord(
                        scope: plan.scope,
                        action: .failed,
                        path: currentCandidate.path,
                        detail: error.localizedDescription
                    ))
                }
            }
        }

        appendHistory(records)

        return CleanupRunResult(
            trashedPaths: trashedPaths,
            rejectedItems: rejectedItems,
            failedPaths: failedPaths
        )
    }

    func permanentlyDeleteTrashItems(
        _ plan: CleanupPlan,
        trashRootDevice: UInt64,
        trashRootInode: UInt64,
        whitelist: [String] = CleanupPreferences.whitelist()
    ) -> CleanupRunResult {
        guard plan.scope == .trash else {
            let rejected = plan.candidates.map {
                CleanupRejectedItem(path: $0.path, reason: .protected)
            }
            return CleanupRunResult(
                trashedPaths: [],
                rejectedItems: plan.rejectedItems + rejected,
                failedPaths: []
            )
        }
        guard Date().timeIntervalSince(plan.createdAt) <= planLifetime else {
            let rejected = plan.candidates.map {
                CleanupRejectedItem(path: $0.path, reason: .expired)
            }
            appendHistory(rejected.map {
                historyRecord(scope: plan.scope, action: .skipped, path: $0.path, detail: $0.reason.rawValue)
            })
            return CleanupRunResult(trashedPaths: [], rejectedItems: plan.rejectedItems + rejected, failedPaths: [])
        }

        let trashRoot = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".Trash", isDirectory: true)
            .standardizedFileURL.path
        guard let currentRoot = fileIdentity(at: trashRoot),
              currentRoot.device == trashRootDevice,
              currentRoot.inode == trashRootInode else {
            let rejected = plan.candidates.map {
                CleanupRejectedItem(path: $0.path, reason: .changed)
            }
            appendHistory(rejected.map {
                historyRecord(scope: plan.scope, action: .skipped, path: $0.path, detail: $0.reason.rawValue)
            })
            return CleanupRunResult(trashedPaths: [], rejectedItems: plan.rejectedItems + rejected, failedPaths: [])
        }

        var deletedPaths: [String] = []
        var rejectedItems = plan.rejectedItems
        var failedPaths: [String] = []
        var records: [CleanupOperationRecord] = []

        for plannedCandidate in plan.candidates {
            let parent = URL(fileURLWithPath: plannedCandidate.path)
                .deletingLastPathComponent()
                .standardizedFileURL.path
            guard pathsEqual(parent, trashRoot) else {
                let rejected = CleanupRejectedItem(path: plannedCandidate.path, reason: .protected)
                rejectedItems.append(rejected)
                records.append(historyRecord(
                    scope: plan.scope,
                    action: .skipped,
                    path: rejected.path,
                    detail: rejected.reason.rawValue
                ))
                continue
            }

            switch validate(path: plannedCandidate.path, whitelist: whitelist) {
            case let .failure(reason):
                let rejected = CleanupRejectedItem(path: plannedCandidate.path, reason: reason)
                rejectedItems.append(rejected)
                records.append(historyRecord(
                    scope: plan.scope,
                    action: .skipped,
                    path: rejected.path,
                    detail: reason.rawValue
                ))
            case let .success(currentCandidate):
                guard currentCandidate.device == plannedCandidate.device,
                      currentCandidate.inode == plannedCandidate.inode else {
                    let rejected = CleanupRejectedItem(path: plannedCandidate.path, reason: .changed)
                    rejectedItems.append(rejected)
                    records.append(historyRecord(
                        scope: plan.scope,
                        action: .skipped,
                        path: rejected.path,
                        detail: rejected.reason.rawValue
                    ))
                    continue
                }
                do {
                    try fileManager.removeItem(atPath: currentCandidate.path)
                    deletedPaths.append(currentCandidate.path)
                    records.append(historyRecord(
                        scope: plan.scope,
                        action: .deleted,
                        path: currentCandidate.path,
                        detail: nil
                    ))
                } catch {
                    failedPaths.append(currentCandidate.path)
                    records.append(historyRecord(
                        scope: plan.scope,
                        action: .failed,
                        path: currentCandidate.path,
                        detail: error.localizedDescription
                    ))
                }
            }
        }

        appendHistory(records)
        return CleanupRunResult(
            trashedPaths: deletedPaths,
            rejectedItems: rejectedItems,
            failedPaths: failedPaths
        )
    }

    func history() -> [CleanupOperationRecord] {
        loadHistory()
    }

    func recordRejectedItems(_ items: [CleanupRejectedItem], scope: CleanupScope) {
        appendHistory(items.map {
            historyRecord(scope: scope, action: .skipped, path: $0.path, detail: $0.reason.rawValue)
        })
    }

    func eligiblePaths(
        _ paths: [String],
        whitelist: [String] = CleanupPreferences.whitelist()
    ) -> Set<String> {
        Set(paths.compactMap { path in
            guard case let .success(candidate) = validate(path: path, whitelist: whitelist) else {
                return nil
            }
            return candidate.path
        })
    }

    func clearHistory() throws {
        let url = try historyURL()
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private func validate(path rawPath: String, whitelist: [String]) -> Result<CleanupCandidate, CleanupRejection> {
        guard !rawPath.isEmpty,
              rawPath.hasPrefix("/"),
              !rawPath.contains("\0"),
              !rawPath.split(separator: "/", omittingEmptySubsequences: false).contains("..") else {
            return .failure(.invalidPath)
        }

        let standardized = URL(fileURLWithPath: rawPath).standardizedFileURL.path
        guard let identity = fileIdentity(at: standardized) else {
            return .failure(.missing)
        }
        let canonical = URL(fileURLWithPath: standardized).resolvingSymlinksInPath().standardizedFileURL.path
        guard !isProtected(path: standardized), !isProtected(path: canonical) else {
            return .failure(.protected)
        }
        guard !isWhitelisted(path: standardized, whitelist: whitelist),
              !isWhitelisted(path: canonical, whitelist: whitelist) else {
            return .failure(.whitelisted)
        }

        return .success(CleanupCandidate(
            path: standardized,
            canonicalPath: canonical,
            device: identity.device,
            inode: identity.inode
        ))
    }

    private func fileIdentity(at path: String) -> (device: UInt64, inode: UInt64)? {
        var value = stat()
        let result = path.withCString { lstat($0, &value) }
        guard result == 0 else { return nil }
        return (UInt64(value.st_dev), UInt64(value.st_ino))
    }

    private func isWhitelisted(path: String, whitelist: [String]) -> Bool {
        whitelist.contains { protectedPath in
            let protected = URL(fileURLWithPath: protectedPath).standardizedFileURL.path
            return pathsOverlap(path, protected)
        }
    }

    private func isProtected(path: String) -> Bool {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        let home = fileManager.homeDirectoryForCurrentUser.standardizedFileURL.path

        let exactPaths = [
            "/", "/Applications", "/Library", "/Library/Application Support", "/System",
            "/Users", "/Volumes", "/Network", "/cores", "/dev", "/etc", "/home",
            "/net", "/tmp", "/var", "/private", "/private/etc", "/private/tmp",
            "/private/var", "/private/var/audit", "/private/var/db", "/private/var/root",
            "/private/var/tmp", "/private/var/folders", "/bin", "/sbin", "/usr", "/opt",
            "/opt/homebrew", home,
            Bundle.main.bundleURL.standardizedFileURL.path
        ]
        if exactPaths.contains(where: { pathsEqual(normalized, $0) }) {
            return true
        }

        let protectedTrees = [
            "/System", "/bin", "/sbin", "/usr", "/private/etc", "/private/var/audit",
            "/private/var/db", "/private/var/root", "/Library/Apple", "/Library/Extensions",
            "/Library/Keychains", "/Applications/Finder.app", "/Applications/Safari.app",
            "/dev", home + "/Library/Containers/com.docker.docker", home + "/.orbstack"
        ]
        if protectedTrees.contains(where: { pathIsInside(normalized, root: $0) }) {
            return true
        }

        let parent = URL(fileURLWithPath: normalized).deletingLastPathComponent().standardizedFileURL.path
        if pathsEqual(parent, "/Users") {
            return true
        }

        let lowercased = normalized.lowercased()
        if lowercased.hasPrefix("/private/var/folders/") || lowercased.hasPrefix("/var/folders/") {
            let endpointSecurityPrefixes = [
                "com.crowdstrike.", "com.sentinelone.", "com.sentinel-labs.", "com.eset.",
                "com.jamf.", "com.jamfsoftware.", "com.paloaltonetworks.",
                "com.cisco.anyconnect", "com.cisco.secureclient"
            ]
            if endpointSecurityPrefixes.contains(where: lowercased.contains) {
                return true
            }
        }

        let groupContainers = home + "/Library/Group Containers/"
        if lowercased.hasPrefix(groupContainers.lowercased()) {
            let relative = String(normalized.dropFirst(groupContainers.count))
            if relative.split(separator: "/").first?.lowercased().hasSuffix("dev.orbstack") == true {
                return true
            }
        }

        let userCaches = home + "/Library/Caches"
        let cacheRelativePath = pathIsInside(normalized, root: userCaches)
            ? String(normalized.dropFirst(userCaches.count + 1))
            : nil
        let topCacheName = cacheRelativePath?.split(separator: "/").first.map(String.init)?.lowercased()
        if topCacheName?.hasPrefix("com.apple.fontregistry") == true
            || topCacheName?.hasPrefix("com.apple.spotlight") == true
            || topCacheName?.hasPrefix("cloudkit") == true {
            return true
        }
        let poetryVirtualEnvironments = userCaches + "/pypoetry/virtualenvs"
        if pathsOverlap(normalized, poetryVirtualEnvironments)
            || cacheRelativePath?.lowercased().hasPrefix("pypoetry/virtualenvs") == true {
            return true
        }

        let denoRoot = ProcessInfo.processInfo.environment["DENO_DIR"]
            ?? userCaches + "/deno"
        if isValidOwnerCacheRoot(denoRoot, home: home) {
            if pathsOverlap(normalized, URL(fileURLWithPath: denoRoot).standardizedFileURL.path) {
                return true
            }
        } else if pathIsInside(normalized, root: userCaches) {
            return true
        }

        if normalized.lowercased().hasSuffix("/com.apple.e5rt.e5bundlecache")
            || fileManager.fileExists(atPath: normalized + "/com.apple.e5rt.e5bundlecache") {
            return true
        }
        return false
    }

    private func isValidOwnerCacheRoot(_ path: String, home: String) -> Bool {
        guard path.hasPrefix("/"),
              !path.contains("\0"),
              !path.contains("//"),
              !path.split(separator: "/", omittingEmptySubsequences: false).contains("."),
              !path.split(separator: "/", omittingEmptySubsequences: false).contains("..") else {
            return false
        }
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        let invalidRoots = ["/", home, home + "/Library", home + "/Library/Caches", home + "/.cache"]
        return !invalidRoots.contains { pathsEqual(normalized, $0) }
    }

    private func pathIsInside(_ path: String, root: String) -> Bool {
        pathsEqual(path, root) || path.lowercased().hasPrefix(root.lowercased() + "/")
    }

    private func pathsOverlap(_ lhs: String, _ rhs: String) -> Bool {
        pathIsInside(lhs, root: rhs) || pathIsInside(rhs, root: lhs)
    }

    private func pathsEqual(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: [.caseInsensitive, .literal]) == .orderedSame
    }

    private func historyRecord(
        scope: CleanupScope,
        action: CleanupOperationAction,
        path: String,
        detail: String?
    ) -> CleanupOperationRecord {
        CleanupOperationRecord(
            id: UUID(),
            date: Date(),
            scope: scope,
            action: action,
            path: path,
            detail: detail
        )
    }

    private func appendHistory(_ newRecords: [CleanupOperationRecord]) {
        guard !newRecords.isEmpty else { return }
        var records = loadHistory()
        records.insert(contentsOf: newRecords.reversed(), at: 0)
        if records.count > maximumHistoryCount {
            records.removeSubrange(maximumHistoryCount...)
        }
        do {
            let url = try historyURL()
            let data = try JSONEncoder().encode(records)
            try data.write(to: url, options: .atomic)
        } catch {
            // Cleanup must not fail because its optional audit trail cannot be persisted.
        }
    }

    private func loadHistory() -> [CleanupOperationRecord] {
        guard let url = try? historyURL(),
              let data = try? Data(contentsOf: url),
              let records = try? JSONDecoder().decode([CleanupOperationRecord].self, from: data) else {
            return []
        }
        return records
    }

    private func historyURL() throws -> URL {
        let root = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Moni", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("cleanup-history.json")
    }
}

nonisolated private extension Array where Element == String {
    func uniqued() -> [String] {
        var seen: Set<String> = []
        return filter { seen.insert($0).inserted }
    }
}
