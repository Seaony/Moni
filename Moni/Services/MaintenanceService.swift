import Darwin
import Foundation

enum MaintenanceCategory: String, CaseIterable, Sendable {
    case system
    case finder
    case storage
    case privacy

    var titleKey: String {
        switch self {
        case .system: "System"
        case .finder: "Finder"
        case .storage: "Storage"
        case .privacy: "Privacy"
        }
    }
}

enum MaintenanceAuthorization: Sendable {
    case user
    case administrator
}

enum MaintenanceExecutionPolicy: Sendable {
    case immediate
    case requiresInactiveApplications
}

struct MaintenanceTaskDefinition: Identifiable, Sendable {
    let id: String
    let titleKey: String
    let descriptionKey: String
    let symbol: String
    let category: MaintenanceCategory
    let authorization: MaintenanceAuthorization
    let executionPolicy: MaintenanceExecutionPolicy
}

nonisolated struct FinderMaintenanceSnapshot: Sendable {
    let cachePaths: [String]
    let staleSavedStatePaths: [String]
    let unreadableItemCount: Int
}

nonisolated struct FinderRefreshResult: Sendable {
    let quickLookCacheRefreshed: Bool
    let iconServicesRefreshed: Bool
    let unavailable: Bool
}

nonisolated struct BrokenPreferenceSnapshot: Sendable {
    let paths: [String]
    let unreadableItemCount: Int
}

nonisolated struct MaintenanceFileRepairSnapshot: Sendable {
    let brokenSharedFileListPaths: [String]
    let brokenLaunchAgentPaths: [String]
    let unreadableItemCount: Int
}

nonisolated enum MaintenanceService {
    private struct FinderMaintenanceScan: Sendable {
        let cachePaths: [String]
        let savedStatePaths: [String]
        let unreadableItemCount: Int
    }

    static let tasks: [MaintenanceTaskDefinition] = [
        task(
            "system_maintenance", "DNS & Spotlight Check",
            "Refresh DNS cache and verify Spotlight status.", "checkmark.shield",
            .system, authorization: .administrator
        ),
        task(
            "cache_refresh", "Finder Cache Refresh",
            "Refresh Quick Look thumbnails and icon services caches.", "photo.stack",
            .finder
        ),
        task(
            "saved_state_cleanup", "App State Cleanup",
            "Remove saved application states that have not changed for more than 30 days.",
            "clock.arrow.circlepath", .storage
        ),
        task(
            "fix_broken_configs", "Broken Config Repair",
            "Find malformed third-party preference files so they can be safely reset.",
            "wrench.and.screwdriver", .system
        ),
        task(
            "network_optimization", "Network Cache Refresh",
            "Flush the DNS cache and restart mDNSResponder.", "network",
            .system, authorization: .administrator
        ),
        task(
            "sqlite_vacuum", "Database Optimization",
            "Compact supported Mail, Safari, and Messages databases while their apps are closed.",
            "cylinder.split.1x2", .storage, policy: .requiresInactiveApplications
        ),
        task(
            "launch_services_rebuild", "LaunchServices Repair",
            "Rebuild file associations and the Open With menu.", "doc.badge.gearshape",
            .system
        ),
        task(
            "prevent_network_dsstore", "Prevent Finder .DS_Store",
            "Stop Finder from writing .DS_Store files on network and USB volumes.",
            "externaldrive.badge.xmark", .finder
        ),
        task(
            "legacy_overrides_audit", "Legacy Overrides",
            "Remove hidden App Nap and disk-image verification overrides left by old tweak tools.",
            "slider.horizontal.3", .system
        ),
        task(
            "network_stack_optimize", "Network Stack Refresh",
            "Flush routing and ARP caches to resolve network issues.", "point.3.connected.trianglepath.dotted",
            .system, authorization: .administrator
        ),
        task(
            "disk_permissions_repair", "Permission Repair",
            "Reset permissions for the current user home directory.", "person.badge.key",
            .system, authorization: .administrator
        ),
        task(
            "spotlight_index_optimize", "Spotlight Optimization",
            "Inspect Spotlight and rebuild the startup volume index only when needed.",
            "magnifyingglass.circle", .system, authorization: .administrator
        ),
        task(
            "spotlight_orphan_rules_cleanup", "Spotlight Orphan Rules",
            "Remove Spotlight search rules that reference applications no longer installed.",
            "magnifyingglass", .system
        ),
        task(
            "periodic_maintenance", "Periodic Maintenance",
            "Run macOS daily, weekly, and monthly maintenance scripts when stale.",
            "calendar.badge.clock", .system, authorization: .administrator
        ),
        task(
            "tart_cache_prune", "Tart Cache Pruning",
            "Prune Tart cache entries older than 30 days using Tart's own maintenance command.",
            "shippingbox", .storage, policy: .requiresInactiveApplications
        ),
        task(
            "time_machine_snapshots", "Time Machine",
            "Report local snapshots and review incomplete backups for removal with tmutil.",
            "clock.arrow.trianglehead.counterclockwise.rotate.90", .storage
        ),
        task(
            "deep_system_cleanup", "System Cleanup",
            "Scan old system caches and logs before approving cleanup.",
            "externaldrive.badge.minus", .storage, authorization: .administrator
        ),
        task(
            "shared_file_list_repair", "Shared File Lists",
            "Repair malformed Finder favorites and recent-item lists.", "list.bullet.rectangle",
            .finder
        ),
        task(
            "disk_verify", "Disk Health",
            "Verify the startup filesystem without modifying it.", "internaldrive",
            .storage
        ),
        task(
            "login_items_audit", "Login Items",
            "Find login items whose referenced application or executable no longer exists.",
            "rectangle.stack.badge.person.crop", .system
        ),
        task(
            "quarantine_cleanup", "Quarantine Database Cleanup",
            "Clear Gatekeeper download history without changing file quarantine flags.",
            "lock.doc", .privacy
        ),
        task(
            "launch_agents_cleanup", "Launch Agents Cleanup",
            "Find user LaunchAgents whose referenced executable no longer exists.",
            "bolt.badge.xmark", .system
        ),
        task(
            "notification_cleanup", "Notifications",
            "Remove old delivered notifications to reduce notification database size.",
            "bell.badge", .privacy
        ),
        task(
            "coreduet_cleanup", "Usage Data",
            "Remove old local usage-tracking records from supported system databases.",
            "chart.bar.xaxis", .privacy
        )
    ]

    static func scanFinderMaintenance(referenceDate: Date = Date()) async -> FinderMaintenanceSnapshot {
        let scan = await Task.detached(priority: .utility) {
            scanFinderPaths(referenceDate: referenceDate)
        }.value
        let eligiblePaths = await CleanupService.shared.eligiblePaths(scan.cachePaths + scan.savedStatePaths)
        return FinderMaintenanceSnapshot(
            cachePaths: scan.cachePaths.filter(eligiblePaths.contains).sorted(by: localizedPathOrder),
            staleSavedStatePaths: scan.savedStatePaths.filter(eligiblePaths.contains).sorted(by: localizedPathOrder),
            unreadableItemCount: scan.unreadableItemCount
        )
    }

    private static func scanFinderPaths(referenceDate: Date) -> FinderMaintenanceScan {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser.standardizedFileURL.path
        let cachePaths = [
            home + "/Library/Caches/com.apple.QuickLook.thumbnailcache",
            home + "/Library/Caches/com.apple.iconservices.store",
            home + "/Library/Caches/com.apple.iconservices"
        ].filter { fileManager.fileExists(atPath: $0) }

        let savedStateRoot = URL(
            fileURLWithPath: home + "/Library/Saved Application State",
            isDirectory: true
        )
        var savedStatePaths: [String] = []
        var unreadableItemCount = 0
        if let enumerator = fileManager.enumerator(
            at: savedStateRoot,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey],
            options: [],
            errorHandler: { _, _ in
                unreadableItemCount += 1
                return true
            }
        ) {
            let cutoffDate = referenceDate.addingTimeInterval(-30 * 24 * 60 * 60)
            for case let url as URL in enumerator {
                guard !Task.isCancelled else { break }
                guard url.pathExtension == "savedState" else { continue }
                do {
                    let values = try url.resourceValues(forKeys: [
                        .contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey
                    ])
                    guard values.isDirectory == true, values.isSymbolicLink != true else {
                        enumerator.skipDescendants()
                        continue
                    }
                    if let modificationDate = values.contentModificationDate,
                       modificationDate < cutoffDate {
                        savedStatePaths.append(url.standardizedFileURL.path)
                    }
                    enumerator.skipDescendants()
                } catch {
                    unreadableItemCount += 1
                    enumerator.skipDescendants()
                }
            }
        } else if fileManager.fileExists(atPath: savedStateRoot.path) {
            unreadableItemCount += 1
        }

        return FinderMaintenanceScan(
            cachePaths: cachePaths,
            savedStatePaths: savedStatePaths,
            unreadableItemCount: unreadableItemCount
        )
    }

    static func refreshFinderServices() async -> FinderRefreshResult {
        await Task.detached(priority: .utility) {
            let executable = "/usr/bin/qlmanage"
            guard FileManager.default.isExecutableFile(atPath: executable) else {
                return FinderRefreshResult(
                    quickLookCacheRefreshed: false,
                    iconServicesRefreshed: false,
                    unavailable: true
                )
            }
            return FinderRefreshResult(
                quickLookCacheRefreshed: run(executable, arguments: ["-r", "cache"]),
                iconServicesRefreshed: run(executable, arguments: ["-r"]),
                unavailable: false
            )
        }.value
    }

    static func scanBrokenPreferences() async -> BrokenPreferenceSnapshot {
        let scan = await Task.detached(priority: .utility) {
            scanPreferencePaths()
        }.value
        let eligiblePaths = await CleanupService.shared.eligiblePaths(scan.paths)
        return BrokenPreferenceSnapshot(
            paths: scan.paths.filter(eligiblePaths.contains).sorted(by: localizedPathOrder),
            unreadableItemCount: scan.unreadableItemCount
        )
    }

    static func scanFileRepairs() async -> MaintenanceFileRepairSnapshot {
        let scan = await Task.detached(priority: .utility) {
            scanFileRepairPaths()
        }.value
        let paths = scan.brokenSharedFileListPaths + scan.brokenLaunchAgentPaths
        let eligiblePaths = await CleanupService.shared.eligiblePaths(paths)
        return MaintenanceFileRepairSnapshot(
            brokenSharedFileListPaths: scan.brokenSharedFileListPaths
                .filter(eligiblePaths.contains)
                .sorted(by: localizedPathOrder),
            brokenLaunchAgentPaths: scan.brokenLaunchAgentPaths
                .filter(eligiblePaths.contains)
                .sorted(by: localizedPathOrder),
            unreadableItemCount: scan.unreadableItemCount
        )
    }

    static func unloadUserLaunchAgents(_ candidates: [CleanupCandidate]) async {
        await Task.detached(priority: .utility) {
            let root = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
                .standardizedFileURL.path + "/"
            for candidate in candidates {
                let url = URL(fileURLWithPath: candidate.path).standardizedFileURL
                guard url.path.hasPrefix(root),
                      url.deletingLastPathComponent().path + "/" == root,
                      url.pathExtension.lowercased() == "plist",
                      matchesIdentity(candidate) else { continue }
                _ = run("/bin/launchctl", arguments: ["unload", candidate.path])
            }
        }.value
    }

    private static func task(
        _ id: String,
        _ titleKey: String,
        _ descriptionKey: String,
        _ symbol: String,
        _ category: MaintenanceCategory,
        authorization: MaintenanceAuthorization = .user,
        policy: MaintenanceExecutionPolicy = .immediate
    ) -> MaintenanceTaskDefinition {
        MaintenanceTaskDefinition(
            id: id,
            titleKey: titleKey,
            descriptionKey: descriptionKey,
            symbol: symbol,
            category: category,
            authorization: authorization,
            executionPolicy: policy
        )
    }

    private static func run(_ executable: String, arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func localizedPathOrder(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedStandardCompare(rhs) == .orderedAscending
    }

    private static func scanPreferencePaths() -> BrokenPreferenceSnapshot {
        let fileManager = FileManager.default
        let preferencesURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences", isDirectory: true)
        var candidates: [URL] = []
        var unreadableItemCount = 0

        do {
            let topLevel = try fileManager.contentsOfDirectory(
                at: preferencesURL,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
            candidates.append(contentsOf: topLevel.filter {
                isPreferenceCandidate($0, protectLoginWindow: true)
            })
        } catch {
            if fileManager.fileExists(atPath: preferencesURL.path) {
                unreadableItemCount += 1
            }
        }

        let byHostURL = preferencesURL.appendingPathComponent("ByHost", isDirectory: true)
        if let enumerator = fileManager.enumerator(
            at: byHostURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in
                unreadableItemCount += 1
                return true
            }
        ) {
            for case let url as URL in enumerator {
                guard !Task.isCancelled else { break }
                if isPreferenceCandidate(url, protectLoginWindow: false) {
                    candidates.append(url)
                }
            }
        } else if fileManager.fileExists(atPath: byHostURL.path) {
            unreadableItemCount += 1
        }

        var brokenPaths: [String] = []
        for url in candidates {
            guard !Task.isCancelled else { break }
            guard fileManager.isReadableFile(atPath: url.path) else {
                unreadableItemCount += 1
                continue
            }
            if !run("/usr/bin/plutil", arguments: ["-lint", url.path]) {
                brokenPaths.append(url.standardizedFileURL.path)
            }
        }

        return BrokenPreferenceSnapshot(
            paths: brokenPaths,
            unreadableItemCount: unreadableItemCount
        )
    }

    private static func isPreferenceCandidate(_ url: URL, protectLoginWindow: Bool) -> Bool {
        guard url.pathExtension == "plist" else { return false }
        let filename = url.lastPathComponent
        guard !filename.hasPrefix("com.apple."),
              !filename.hasPrefix(".GlobalPreferences"),
              !(protectLoginWindow && filename == "loginwindow.plist") else {
            return false
        }
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private static func scanFileRepairPaths() -> MaintenanceFileRepairSnapshot {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let sharedFileListRoot = home.appendingPathComponent(
            "Library/Application Support/com.apple.sharedfilelist",
            isDirectory: true
        )
        var sharedFileLists: [String] = []
        var launchAgents: [String] = []
        var unreadableItemCount = 0

        if let enumerator = fileManager.enumerator(
            at: sharedFileListRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in
                unreadableItemCount += 1
                return true
            }
        ) {
            for case let url as URL in enumerator {
                guard !Task.isCancelled else { break }
                guard !url.path.contains("ApplicationRecentDocuments"),
                      ["sfl2", "sfl3"].contains(url.pathExtension.lowercased()),
                      isRegularNonSymlink(url) else { continue }
                guard fileManager.isReadableFile(atPath: url.path) else {
                    unreadableItemCount += 1
                    continue
                }
                if !run("/usr/bin/plutil", arguments: ["-lint", url.path]) {
                    sharedFileLists.append(url.standardizedFileURL.path)
                }
            }
        } else if fileManager.fileExists(atPath: sharedFileListRoot.path) {
            unreadableItemCount += 1
        }

        let launchAgentRoot = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        do {
            let items = try fileManager.contentsOfDirectory(
                at: launchAgentRoot,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
            for url in items where url.pathExtension.lowercased() == "plist" && isRegularNonSymlink(url) {
                guard !Task.isCancelled else { break }
                guard fileManager.isReadableFile(atPath: url.path) else {
                    unreadableItemCount += 1
                    continue
                }
                guard let executablePath = launchAgentExecutablePath(in: url) else { continue }
                guard executablePath.hasPrefix("/"),
                      !fileManager.fileExists(atPath: executablePath),
                      launchAgentVolumeIsMounted(executablePath) else { continue }
                launchAgents.append(url.standardizedFileURL.path)
            }
        } catch {
            if fileManager.fileExists(atPath: launchAgentRoot.path) {
                unreadableItemCount += 1
            }
        }

        return MaintenanceFileRepairSnapshot(
            brokenSharedFileListPaths: sharedFileLists,
            brokenLaunchAgentPaths: launchAgents,
            unreadableItemCount: unreadableItemCount
        )
    }

    private static func isRegularNonSymlink(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private static func launchAgentExecutablePath(in url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let values = plist as? [String: Any] else { return nil }
        if let arguments = values["ProgramArguments"] as? [String],
           let executable = arguments.first,
           !executable.isEmpty {
            return executable
        }
        if let executable = values["Program"] as? String, !executable.isEmpty {
            return executable
        }
        return nil
    }

    private static func launchAgentVolumeIsMounted(_ executablePath: String) -> Bool {
        guard executablePath.hasPrefix("/Volumes/") else { return true }
        let components = executablePath.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count >= 2 else { return false }
        return FileManager.default.fileExists(atPath: "/Volumes/" + components[1])
    }

    private static func matchesIdentity(_ candidate: CleanupCandidate) -> Bool {
        var value = stat()
        let result = candidate.path.withCString { lstat($0, &value) }
        return result == 0
            && UInt64(value.st_dev) == candidate.device
            && UInt64(value.st_ino) == candidate.inode
    }
}
