import Darwin
import Foundation

nonisolated enum ProjectArtifactActivity: String, Sendable {
    case old
    case recent
    case uncertain
}

nonisolated struct ProjectArtifactItem: Identifiable, Sendable {
    let path: String
    let searchRootPath: String
    let projectRootPath: String
    let name: String
    let sizeBytes: UInt64?
    let activity: ProjectArtifactActivity
    let isCloudSynced: Bool

    var id: String { path }

    var isSelectedByDefault: Bool {
        activity == .old && !isCloudSynced
    }
}

nonisolated struct ProjectArtifactSnapshot: Sendable {
    let searchRootPaths: [String]
    let items: [ProjectArtifactItem]
    let failedRootPaths: [String]
}

nonisolated struct ProjectArtifactRootIdentity: Sendable {
    let path: String
    let device: UInt64
    let inode: UInt64
}

nonisolated struct ProjectArtifactCleanupPlan: Identifiable, Sendable {
    let cleanupPlan: CleanupPlan
    let items: [ProjectArtifactItem]
    let rootIdentities: [ProjectArtifactRootIdentity]

    var id: UUID { cleanupPlan.id }
}

nonisolated enum ProjectArtifactService {
    private struct ScanCandidate: Sendable {
        let path: String
        let searchRootPath: String
    }

    private struct RootScanResult: Sendable {
        let candidates: [ScanCandidate]
        let failed: Bool
    }

    private struct ArtifactDetails: Sendable {
        let sizeBytes: UInt64?
        let activity: ProjectArtifactActivity
    }

    private struct FileIdentity: Hashable {
        let device: UInt64
        let inode: UInt64
    }

    private static let maximumScanDepth = 6
    private static let minimumAge: TimeInterval = 7 * 24 * 60 * 60
    private static let rootScanTimeLimit: TimeInterval = 60
    private static let artifactScanTimeLimit: TimeInterval = 15
    private static let cacheTagName = "CACHEDIR.TAG"
    private static let cacheTagSignature = "Signature: 8a477f597d28d172789f06886806bc55"

    private static let artifactNames: Set<String> = [
        "node_modules", "target", "build", "dist", "venv", ".venv",
        ".pytest_cache", ".mypy_cache", ".tox", ".nox", ".ruff_cache",
        ".gradle", ".terragrunt-cache", "__pycache__", ".next", ".nuxt",
        ".output", "vendor", "bin", "obj", ".turbo", ".parcel-cache",
        ".dart_tool", ".zig-cache", "zig-out", ".angular", ".svelte-kit",
        ".astro", "coverage", "DerivedData", "Pods", ".cxx", ".expo", ".build"
    ]

    private static let monorepoIndicators = [
        "lerna.json", "pnpm-workspace.yaml", "nx.json", "rush.json", ".git"
    ]

    private static let projectIndicators = [
        "package.json", "Cargo.toml", "go.mod", "pyproject.toml", "requirements.txt",
        "pom.xml", "build.gradle", "terragrunt.hcl", "Gemfile", "composer.json",
        "pubspec.yaml", "Package.swift", "Makefile", "build.zig", "build.zig.zon", ".git"
    ]

    private static let excludedContainerNames: Set<String> = [
        "Library", "Applications", "Movies", "Music", "Pictures", "Public"
    ]

    private static let prunedDirectoryNames: Set<String> = [
        ".git", "Library", ".Trash", "Applications"
    ]

    static func scan(referenceDate: Date = Date()) async -> ProjectArtifactSnapshot {
        let rawSnapshot = await Task.detached(priority: .utility) {
            scanSynchronously(referenceDate: referenceDate)
        }.value
        guard !Task.isCancelled else {
            return ProjectArtifactSnapshot(searchRootPaths: [], items: [], failedRootPaths: [])
        }

        let eligiblePaths = await CleanupService.shared.eligiblePaths(rawSnapshot.items.map(\.path))
        return ProjectArtifactSnapshot(
            searchRootPaths: rawSnapshot.searchRootPaths,
            items: rawSnapshot.items.filter { eligiblePaths.contains($0.path) },
            failedRootPaths: rawSnapshot.failedRootPaths
        )
    }

    static func previewCleanup(items: [ProjectArtifactItem]) async -> ProjectArtifactCleanupPlan {
        let validation = await Task.detached(priority: .utility) {
            validateForPreview(items)
        }.value
        let basePlan = await CleanupService.shared.preview(
            paths: validation.items.map(\.path),
            scope: .projects
        )
        await CleanupService.shared.recordRejectedItems(validation.rejectedItems, scope: .projects)
        let cleanupPlan = CleanupPlan(
            id: basePlan.id,
            createdAt: basePlan.createdAt,
            scope: basePlan.scope,
            candidates: basePlan.candidates,
            rejectedItems: basePlan.rejectedItems + validation.rejectedItems
        )
        return ProjectArtifactCleanupPlan(
            cleanupPlan: cleanupPlan,
            items: validation.items,
            rootIdentities: validation.rootIdentities
        )
    }

    static func executeCleanup(_ plan: ProjectArtifactCleanupPlan) async -> CleanupRunResult {
        let validation = await Task.detached(priority: .utility) {
            revalidateForExecution(plan)
        }.value
        await CleanupService.shared.recordRejectedItems(validation.rejectedItems, scope: .projects)
        let finalPlan = CleanupPlan(
            id: plan.cleanupPlan.id,
            createdAt: plan.cleanupPlan.createdAt,
            scope: plan.cleanupPlan.scope,
            candidates: plan.cleanupPlan.candidates.filter { validation.allowedPaths.contains($0.path) },
            rejectedItems: plan.cleanupPlan.rejectedItems + validation.rejectedItems
        )
        return await CleanupService.shared.execute(finalPlan)
    }

    private static func validateForPreview(_ items: [ProjectArtifactItem]) -> (
        items: [ProjectArtifactItem],
        rootIdentities: [ProjectArtifactRootIdentity],
        rejectedItems: [CleanupRejectedItem]
    ) {
        var rootIdentities: [String: ProjectArtifactRootIdentity] = [:]
        var validItems: [ProjectArtifactItem] = []
        var rejectedItems: [CleanupRejectedItem] = []

        for item in items {
            guard isSafeArtifact(item.path, under: item.searchRootPath),
                  let currentProjectRoot = projectRoot(for: item.path),
                  pathsEqual(currentProjectRoot, item.projectRootPath) else {
                rejectedItems.append(CleanupRejectedItem(path: item.path, reason: .changed))
                continue
            }
            guard !isProtectedArtifact(item.path) else {
                rejectedItems.append(CleanupRejectedItem(path: item.path, reason: .protected))
                continue
            }
            guard let identity = fileIdentity(at: item.searchRootPath) else {
                rejectedItems.append(CleanupRejectedItem(path: item.path, reason: .changed))
                continue
            }
            rootIdentities[item.searchRootPath] = ProjectArtifactRootIdentity(
                path: item.searchRootPath,
                device: identity.device,
                inode: identity.inode
            )
            validItems.append(item)
        }

        return (
            validItems,
            rootIdentities.values.sorted { localizedPathOrder($0.path, $1.path) },
            rejectedItems
        )
    }

    private static func revalidateForExecution(_ plan: ProjectArtifactCleanupPlan) -> (
        allowedPaths: Set<String>,
        rejectedItems: [CleanupRejectedItem]
    ) {
        let expectedRoots = Dictionary(uniqueKeysWithValues: plan.rootIdentities.map { ($0.path, $0) })
        var allowedPaths: Set<String> = []
        var rejectedItems: [CleanupRejectedItem] = []

        for item in plan.items {
            guard let expectedRoot = expectedRoots[item.searchRootPath],
                  let currentRoot = fileIdentity(at: item.searchRootPath),
                  currentRoot.device == expectedRoot.device,
                  currentRoot.inode == expectedRoot.inode,
                  isSafeArtifact(item.path, under: item.searchRootPath),
                  !isProtectedArtifact(item.path),
                  let currentProjectRoot = projectRoot(for: item.path),
                  pathsEqual(currentProjectRoot, item.projectRootPath) else {
                rejectedItems.append(CleanupRejectedItem(path: item.path, reason: .changed))
                continue
            }
            if item.activity == .old,
               classifyActivity(at: item.path, referenceDate: Date()) != .old {
                rejectedItems.append(CleanupRejectedItem(path: item.path, reason: .changed))
                continue
            }
            allowedPaths.insert(item.path)
        }
        return (allowedPaths, rejectedItems)
    }

    private static func scanSynchronously(referenceDate: Date) -> ProjectArtifactSnapshot {
        let roots = discoverSearchRoots()
        var candidates: [ScanCandidate] = []
        var failedRoots: [String] = []

        for root in roots {
            guard !Task.isCancelled else {
                return ProjectArtifactSnapshot(searchRootPaths: roots, items: [], failedRootPaths: [])
            }
            let result = scanRoot(root)
            if result.failed {
                failedRoots.append(root)
            } else {
                candidates.append(contentsOf: result.candidates)
            }
        }

        let filteredCandidates = filterNestedCandidates(candidates)
        var items: [ProjectArtifactItem] = []
        for candidate in filteredCandidates {
            guard !Task.isCancelled else {
                return ProjectArtifactSnapshot(searchRootPaths: roots, items: [], failedRootPaths: [])
            }
            guard isSafeArtifact(candidate.path, under: candidate.searchRootPath),
                  !isProtectedArtifact(candidate.path),
                  let projectRoot = projectRoot(for: candidate.path) else {
                continue
            }
            let details = artifactDetails(at: candidate.path, referenceDate: referenceDate)
            items.append(ProjectArtifactItem(
                path: candidate.path,
                searchRootPath: candidate.searchRootPath,
                projectRootPath: projectRoot,
                name: URL(fileURLWithPath: candidate.path).lastPathComponent,
                sizeBytes: details.sizeBytes,
                activity: details.activity,
                isCloudSynced: isCloudSynced(candidate.path)
            ))
        }

        items.sort {
            if $0.projectRootPath != $1.projectRootPath {
                return $0.projectRootPath.localizedStandardCompare($1.projectRootPath) == .orderedAscending
            }
            if $0.sizeBytes != $1.sizeBytes {
                return ($0.sizeBytes ?? 0) > ($1.sizeBytes ?? 0)
            }
            return $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
        return ProjectArtifactSnapshot(
            searchRootPaths: roots,
            items: items,
            failedRootPaths: failedRoots.sorted(by: localizedPathOrder)
        )
    }

    private static func discoverSearchRoots() -> [String] {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser.standardizedFileURL.path
        let defaults = [
            "www", "dev", "Projects", "GitHub", "Code", "Workspace", "Repos", "Development",
            "Library/CloudStorage", ".codex/worktrees", ".claude/worktrees"
        ].map { home + "/" + $0 }

        var roots = defaults.compactMap(existingDirectory)
        guard let homeChildren = try? fileManager.contentsOfDirectory(
            at: URL(fileURLWithPath: home, isDirectory: true),
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            return deduplicatedPaths(roots)
        }

        for child in homeChildren {
            guard !Task.isCancelled,
                  let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true,
                  values.isSymbolicLink != true else {
                continue
            }
            let name = child.lastPathComponent
            guard !excludedContainerNames.contains(name),
                  !artifactNames.contains(name),
                  containsProjectIndicator(in: child, maximumDepth: 2) else {
                continue
            }
            roots.append(canonicalDirectoryPath(child))
        }
        return deduplicatedPaths(roots)
    }

    private static func existingDirectory(_ path: String) -> String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        return canonicalDirectoryPath(URL(fileURLWithPath: path, isDirectory: true))
    }

    private static func containsProjectIndicator(in root: URL, maximumDepth: Int) -> Bool {
        let fileManager = FileManager.default
        let rootDepth = root.pathComponents.count
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return false
        }

        while let url = enumerator.nextObject() as? URL {
            guard !Task.isCancelled else { return false }
            let depth = url.pathComponents.count - rootDepth
            if depth > maximumDepth {
                enumerator.skipDescendants()
                continue
            }
            if projectIndicators.contains(url.lastPathComponent) {
                return true
            }
            if let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
               values.isDirectory == true,
               values.isSymbolicLink == true {
                enumerator.skipDescendants()
            }
        }
        return false
    }

    private static func scanRoot(_ rootPath: String) -> RootScanResult {
        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        let rootDepth = root.pathComponents.count
        let deadline = Date().addingTimeInterval(rootScanTimeLimit)
        var candidates: [ScanCandidate] = []
        var encounteredError = false

        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [],
            errorHandler: { _, _ in
                encounteredError = true
                return true
            }
        ) else {
            return RootScanResult(candidates: [], failed: true)
        }

        while let url = enumerator.nextObject() as? URL {
            guard !Task.isCancelled, Date() < deadline else {
                return RootScanResult(candidates: [], failed: true)
            }
            let depth = url.pathComponents.count - rootDepth
            if depth > maximumScanDepth + 1 {
                enumerator.skipDescendants()
                continue
            }

            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
                encounteredError = true
                continue
            }
            if values.isSymbolicLink == true {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }

            if values.isDirectory == true {
                let name = url.lastPathComponent
                if prunedDirectoryNames.contains(name) {
                    enumerator.skipDescendants()
                    continue
                }
                if depth >= 1, depth <= maximumScanDepth, artifactNames.contains(name) {
                    candidates.append(ScanCandidate(path: url.standardizedFileURL.path, searchRootPath: rootPath))
                    enumerator.skipDescendants()
                }
                continue
            }

            if url.lastPathComponent == cacheTagName,
               depth >= 2,
               depth <= maximumScanDepth + 1,
               hasValidCacheTag(url) {
                candidates.append(ScanCandidate(
                    path: url.deletingLastPathComponent().standardizedFileURL.path,
                    searchRootPath: rootPath
                ))
            }
        }

        return RootScanResult(candidates: encounteredError ? [] : candidates, failed: encounteredError)
    }

    private static func hasValidCacheTag(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let data = try? handle.read(upToCount: cacheTagSignature.utf8.count)
        return data.flatMap { String(data: $0, encoding: .utf8) } == cacheTagSignature
    }

    private static func filterNestedCandidates(_ candidates: [ScanCandidate]) -> [ScanCandidate] {
        let sorted = candidates.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
        var result: [ScanCandidate] = []
        for candidate in sorted {
            guard !result.contains(where: {
                pathsEqual(candidate.searchRootPath, $0.searchRootPath)
                    && pathIsInside(candidate.path, root: $0.path)
            }) else {
                continue
            }
            result.append(candidate)
        }
        return result
    }

    private static func isSafeArtifact(_ path: String, under rootPath: String) -> Bool {
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let standardizedRoot = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        guard standardizedRoot != "/",
              pathIsInside(standardizedPath, root: standardizedRoot),
              !pathsEqual(standardizedPath, standardizedRoot) else {
            return false
        }

        let canonicalPath = URL(fileURLWithPath: standardizedPath).resolvingSymlinksInPath().standardizedFileURL.path
        let canonicalRoot = URL(fileURLWithPath: standardizedRoot).resolvingSymlinksInPath().standardizedFileURL.path
        guard pathIsInside(canonicalPath, root: canonicalRoot),
              !pathsEqual(canonicalPath, canonicalRoot) else {
            return false
        }

        let relativeComponents = Array(URL(fileURLWithPath: standardizedPath).pathComponents
            .dropFirst(URL(fileURLWithPath: standardizedRoot).pathComponents.count))
        return relativeComponents.count > 1 || isProjectRoot(standardizedRoot)
    }

    private static func isProtectedArtifact(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let name = url.lastPathComponent
        let parent = url.deletingLastPathComponent()
        switch name {
        case "bin":
            guard directoryContainsProjectFile(parent, extensions: ["csproj", "fsproj", "vbproj"]) else {
                return true
            }
            return !FileManager.default.fileExists(atPath: url.appendingPathComponent("Debug").path)
                && !FileManager.default.fileExists(atPath: url.appendingPathComponent("Release").path)
        case "vendor":
            return !FileManager.default.fileExists(atPath: parent.appendingPathComponent("composer.json").path)
        case "DerivedData":
            let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
            return pathIsInside(path, root: home + "/Library/Developer/Xcode/DerivedData")
        default:
            return false
        }
    }

    private static func directoryContainsProjectFile(_ directory: URL, extensions: Set<String>) -> Bool {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }
        return children.contains { extensions.contains($0.pathExtension.lowercased()) }
    }

    private static func projectRoot(for artifactPath: String) -> String? {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser.standardizedFileURL.path
        var current = URL(fileURLWithPath: artifactPath).deletingLastPathComponent().standardizedFileURL
        var nearestProjectRoot: String?

        while current.path != "/", current.path != home {
            if monorepoIndicators.contains(where: { fileManager.fileExists(atPath: current.appendingPathComponent($0).path) }) {
                return current.path
            }
            if nearestProjectRoot == nil,
               projectIndicators.contains(where: { fileManager.fileExists(atPath: current.appendingPathComponent($0).path) }) {
                nearestProjectRoot = current.path
            }
            current.deleteLastPathComponent()
        }
        return nearestProjectRoot
    }

    private static func isProjectRoot(_ path: String) -> Bool {
        let fileManager = FileManager.default
        return (monorepoIndicators + projectIndicators).contains {
            fileManager.fileExists(atPath: URL(fileURLWithPath: path).appendingPathComponent($0).path)
        }
    }

    private static func artifactDetails(at path: String, referenceDate: Date) -> ArtifactDetails {
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let cutoff = referenceDate.addingTimeInterval(-minimumAge)
        let deadline = Date().addingTimeInterval(artifactScanTimeLimit)
        var activity: ProjectArtifactActivity = .old
        var sizeBytes: UInt64 = 0
        var seenFiles: Set<FileIdentity> = []
        var incomplete = false

        guard let rootMetadata = metadata(at: root) else {
            return ArtifactDetails(sizeBytes: nil, activity: .uncertain)
        }
        sizeBytes = addingWithoutOverflow(sizeBytes, rootMetadata.allocatedBytes)
        if let modifiedDate = rootMetadata.modifiedDate, modifiedDate >= cutoff {
            activity = .recent
        } else if rootMetadata.modifiedDate == nil {
            activity = .uncertain
        }

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { _, _ in
                incomplete = true
                return true
            }
        ) else {
            return ArtifactDetails(sizeBytes: nil, activity: .uncertain)
        }

        while let url = enumerator.nextObject() as? URL {
            guard !Task.isCancelled, Date() < deadline else {
                return ArtifactDetails(sizeBytes: nil, activity: activity == .recent ? .recent : .uncertain)
            }
            guard let itemMetadata = metadata(at: url) else {
                incomplete = true
                continue
            }
            if itemMetadata.isSymbolicLink {
                if itemMetadata.isDirectory { enumerator.skipDescendants() }
                continue
            }
            guard seenFiles.insert(itemMetadata.identity).inserted else { continue }
            sizeBytes = addingWithoutOverflow(sizeBytes, itemMetadata.allocatedBytes)
            if itemMetadata.isRegularFile,
               let modifiedDate = itemMetadata.modifiedDate,
               modifiedDate >= cutoff {
                activity = .recent
            } else if itemMetadata.isRegularFile, itemMetadata.modifiedDate == nil, activity != .recent {
                activity = .uncertain
            }
        }

        if incomplete {
            return ArtifactDetails(sizeBytes: nil, activity: activity == .recent ? .recent : .uncertain)
        }
        return ArtifactDetails(sizeBytes: sizeBytes, activity: activity)
    }

    private static func classifyActivity(at path: String, referenceDate: Date) -> ProjectArtifactActivity {
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let cutoff = referenceDate.addingTimeInterval(-minimumAge)
        let deadline = Date().addingTimeInterval(artifactScanTimeLimit)
        guard let rootMetadata = metadata(at: root),
              let rootModifiedDate = rootMetadata.modifiedDate else {
            return .uncertain
        }
        if rootModifiedDate >= cutoff {
            return .recent
        }

        var incomplete = false
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { _, _ in
                incomplete = true
                return true
            }
        ) else {
            return .uncertain
        }

        while let url = enumerator.nextObject() as? URL {
            guard !Task.isCancelled, Date() < deadline else { return .uncertain }
            guard let itemMetadata = metadata(at: url) else {
                incomplete = true
                continue
            }
            if itemMetadata.isSymbolicLink {
                if itemMetadata.isDirectory { enumerator.skipDescendants() }
                continue
            }
            if itemMetadata.isRegularFile {
                guard let modifiedDate = itemMetadata.modifiedDate else {
                    incomplete = true
                    continue
                }
                if modifiedDate >= cutoff {
                    return .recent
                }
            }
        }
        return incomplete ? .uncertain : .old
    }

    private static func metadata(at url: URL) -> (
        identity: FileIdentity,
        allocatedBytes: UInt64,
        modifiedDate: Date?,
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
            FileIdentity(device: UInt64(value.st_dev), inode: UInt64(value.st_ino)),
            value.st_blocks > 0 ? UInt64(value.st_blocks) * 512 : 0,
            Date(timeIntervalSince1970: TimeInterval(value.st_mtimespec.tv_sec)),
            kind == S_IFDIR,
            kind == S_IFREG,
            kind == S_IFLNK
        )
    }

    private static func fileIdentity(at path: String) -> (device: UInt64, inode: UInt64)? {
        var value = stat()
        let result = path.withCString { lstat($0, &value) }
        guard result == 0 else { return nil }
        return (UInt64(value.st_dev), UInt64(value.st_ino))
    }

    private static func isCloudSynced(_ path: String) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let canonicalHome = URL(fileURLWithPath: home).resolvingSymlinksInPath().standardizedFileURL.path
        let roots = [
            home + "/Library/CloudStorage", home + "/Library/Mobile Documents",
            canonicalHome + "/Library/CloudStorage", canonicalHome + "/Library/Mobile Documents"
        ]
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        return roots.contains { pathIsInside(standardized, root: $0) || pathIsInside(canonical, root: $0) }
    }

    private static func canonicalDirectoryPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func deduplicatedPaths(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        return paths.filter { seen.insert($0.lowercased()).inserted }
            .sorted(by: localizedPathOrder)
    }

    private static func pathIsInside(_ path: String, root: String) -> Bool {
        pathsEqual(path, root) || path.lowercased().hasPrefix(root.lowercased() + "/")
    }

    private static func pathsEqual(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: [.caseInsensitive, .literal]) == .orderedSame
    }

    private static func localizedPathOrder(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedStandardCompare(rhs) == .orderedAscending
    }

    private static func addingWithoutOverflow(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : sum
    }
}
