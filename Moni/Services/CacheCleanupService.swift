import Darwin
import Foundation

nonisolated enum CacheCleanupCategory: String, CaseIterable, Sendable {
    case userCaches
    case userLogs
    case diagnosticReports
    case oldCrashReports
    case messagesPreviewCaches
    case identityAndSuggestionCaches
    case calendarCache
    case addressBookPhotoCaches
    case utmCaches
    case sharedContainerLogs
    case diaProfileCaches
    case chromeProfileCaches
    case firefoxProfileCaches
    case braveProfileCaches
    case arcProfileCaches
    case vivaldiProfileCaches
    case qqBrowserProfileCaches
    case puppeteerCaches
    case heliumProfileCaches
    case browserServiceWorkerCaches
    case browserOldVersions
    case edgeUpdaterOldVersions
    case googleUpdaterCaches
    case virtualizationTemporaryData
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
        case .identityAndSuggestionCaches: "Identity and suggestion caches"
        case .calendarCache: "Calendar cache"
        case .addressBookPhotoCaches: "Address Book photo caches"
        case .utmCaches: "UTM sandbox caches"
        case .sharedContainerLogs: "Shared container logs"
        case .diaProfileCaches: "Dia profile caches"
        case .chromeProfileCaches: "Chrome profile caches"
        case .firefoxProfileCaches: "Firefox profile caches"
        case .braveProfileCaches: "Brave profile caches"
        case .arcProfileCaches: "Arc profile caches"
        case .vivaldiProfileCaches: "Vivaldi profile caches"
        case .qqBrowserProfileCaches: "QQ Browser profile caches"
        case .puppeteerCaches: "Puppeteer browser caches"
        case .heliumProfileCaches: "Helium profile caches"
        case .browserServiceWorkerCaches: "Browser Service Worker caches"
        case .browserOldVersions: "Old browser versions"
        case .edgeUpdaterOldVersions: "Old Edge updater versions"
        case .googleUpdaterCaches: "Google updater caches"
        case .virtualizationTemporaryData: "Virtualization temporary data"
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

    private struct ChromiumVersionSource: Sendable {
        let appPaths: [String]
        let frameworkName: String
        let processProbes: [[String]]
    }

    private struct BrowserServiceWorkerSource: Sendable {
        let cacheRoots: [String]
        let processProbes: [[String]]
    }

    static func scan() async -> CacheCleanupSnapshot {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let userCacheProcessGuard = await Task.detached(priority: .utility) {
            UserCacheProcessGuard.capture()
        }.value
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
                guard size > 0,
                      !name.hasPrefix("."),
                      source.category != .userCaches
                        || UserCacheProcessGuard.permits(path, using: userCacheProcessGuard) else {
                    return nil
                }
                return CacheCleanupItem(path: path, category: source.category, sizeBytes: size)
            })
        }

        discoveredItems.removeAll {
            $0.category == .userCaches
                && (pathsEqual($0.path, diaGeneralCacheRoot())
                    || pathsEqual($0.path, googleGeneralCacheRoot())
                    || pathsEqual($0.path, firefoxGeneralCacheRoot())
                    || pathsEqual($0.path, braveGeneralCacheRoot())
                    || pathsEqual($0.path, arcGeneralCacheRoot())
                    || pathsEqual($0.path, vivaldiGeneralCacheRoot())
                    || pathsEqual($0.path, qqBrowserGeneralCacheRoot())
                    || pathsEqual($0.path, heliumGeneralCacheRoot()))
        }

        let diaIsSafe = await Task.detached(priority: .utility) {
            diaIsInactive()
        }.value
        if diaIsSafe {
            let browserProfileCaches = await scanDiaProfileCaches()
            discoveredItems.append(contentsOf: browserProfileCaches.items)
            unreadableItemCount += browserProfileCaches.unreadableItemCount
        }

        let chromeIsSafe = await Task.detached(priority: .utility) {
            chromeIsInactive()
        }.value
        if chromeIsSafe {
            let chromeProfileCaches = await scanChromeProfileCaches()
            discoveredItems.append(contentsOf: chromeProfileCaches.items)
            unreadableItemCount += chromeProfileCaches.unreadableItemCount
        }

        let firefoxIsSafe = await Task.detached(priority: .utility) {
            firefoxIsInactive()
        }.value
        if firefoxIsSafe {
            let firefoxProfileCaches = await scanFirefoxProfileCaches()
            discoveredItems.append(contentsOf: firefoxProfileCaches.items)
            unreadableItemCount += firefoxProfileCaches.unreadableItemCount
        }

        let braveIsSafe = await Task.detached(priority: .utility) {
            braveIsInactive()
        }.value
        if braveIsSafe {
            let braveProfileCaches = await scanBraveProfileCaches()
            discoveredItems.append(contentsOf: braveProfileCaches.items)
            unreadableItemCount += braveProfileCaches.unreadableItemCount
        }

        let arcIsSafe = await Task.detached(priority: .utility) {
            arcIsInactive()
        }.value
        if arcIsSafe {
            let arcProfileCaches = await scanArcProfileCaches()
            discoveredItems.append(contentsOf: arcProfileCaches.items)
            unreadableItemCount += arcProfileCaches.unreadableItemCount
        }

        let vivaldiIsSafe = await Task.detached(priority: .utility) {
            vivaldiIsInactive()
        }.value
        if vivaldiIsSafe {
            let vivaldiProfileCaches = await scanVivaldiProfileCaches()
            discoveredItems.append(contentsOf: vivaldiProfileCaches.items)
            unreadableItemCount += vivaldiProfileCaches.unreadableItemCount
        }

        let qqBrowserIsSafe = await Task.detached(priority: .utility) {
            qqBrowserIsInactive()
        }.value
        if qqBrowserIsSafe {
            let qqBrowserProfileCaches = await scanQQBrowserProfileCaches()
            discoveredItems.append(contentsOf: qqBrowserProfileCaches.items)
            unreadableItemCount += qqBrowserProfileCaches.unreadableItemCount
        }

        let puppeteerCaches = await scanPuppeteerCaches()
        discoveredItems.append(contentsOf: puppeteerCaches.items)
        unreadableItemCount += puppeteerCaches.unreadableItemCount

        let heliumProcessGuard = await Task.detached(priority: .utility) {
            UserCacheProcessGuard.capture()
        }.value
        if UserCacheProcessGuard.permits(owner: heliumOwner, using: heliumProcessGuard) {
            let heliumProfileCaches = await scanHeliumProfileCaches()
            discoveredItems.append(contentsOf: heliumProfileCaches.items)
            unreadableItemCount += heliumProfileCaches.unreadableItemCount
        }

        let browserServiceWorkerCaches = await scanBrowserServiceWorkerCaches()
        discoveredItems.append(contentsOf: browserServiceWorkerCaches.items)
        unreadableItemCount += browserServiceWorkerCaches.unreadableItemCount

        let browserOldVersions = await scanBrowserOldVersions()
        discoveredItems.append(contentsOf: browserOldVersions.items)
        unreadableItemCount += browserOldVersions.unreadableItemCount

        let edgeUpdaterOldVersions = await scanEdgeUpdaterOldVersions()
        discoveredItems.append(contentsOf: edgeUpdaterOldVersions.items)
        unreadableItemCount += edgeUpdaterOldVersions.unreadableItemCount

        let googleUpdaterCaches = await scanGoogleUpdaterCaches()
        discoveredItems.append(contentsOf: googleUpdaterCaches.items)
        unreadableItemCount += googleUpdaterCaches.unreadableItemCount

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

        let sharedContainerLogs = await scanSharedContainerLogs()
        discoveredItems.append(contentsOf: sharedContainerLogs.items)
        unreadableItemCount += sharedContainerLogs.unreadableItemCount

        let virtualizationTemporaryData = await scanVirtualizationTemporaryData()
        discoveredItems.append(contentsOf: virtualizationTemporaryData.items)
        unreadableItemCount += virtualizationTemporaryData.unreadableItemCount

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

        let identityAndSuggestionCaches = await scanIdentityAndSuggestionCaches()
        discoveredItems.append(contentsOf: identityAndSuggestionCaches.items)
        unreadableItemCount += identityAndSuggestionCaches.unreadableItemCount

        let calendarCache = await scanCalendarCache()
        discoveredItems.append(contentsOf: calendarCache.items)
        unreadableItemCount += calendarCache.unreadableItemCount

        let addressBookPhotoCaches = await scanAddressBookPhotoCaches()
        discoveredItems.append(contentsOf: addressBookPhotoCaches.items)
        unreadableItemCount += addressBookPhotoCaches.unreadableItemCount

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
        let requiresDiaProbe = items.contains { $0.category == .diaProfileCaches }
        let diaIsSafe = !requiresDiaProbe || diaIsInactive()
        let requiresChromeProbe = items.contains { $0.category == .chromeProfileCaches }
        let chromeIsSafe = !requiresChromeProbe || chromeIsInactive()
        let requiresFirefoxProbe = items.contains { $0.category == .firefoxProfileCaches }
        let firefoxIsSafe = !requiresFirefoxProbe || firefoxIsInactive()
        let requiresBraveProbe = items.contains { $0.category == .braveProfileCaches }
        let braveIsSafe = !requiresBraveProbe || braveIsInactive()
        let requiresArcProbe = items.contains { $0.category == .arcProfileCaches }
        let arcIsSafe = !requiresArcProbe || arcIsInactive()
        let requiresVivaldiProbe = items.contains { $0.category == .vivaldiProfileCaches }
        let vivaldiIsSafe = !requiresVivaldiProbe || vivaldiIsInactive()
        let requiresQQBrowserProbe = items.contains { $0.category == .qqBrowserProfileCaches }
        let qqBrowserIsSafe = !requiresQQBrowserProbe || qqBrowserIsInactive()
        let heliumProcessGuard = items.contains { $0.category == .heliumProfileCaches }
            ? UserCacheProcessGuard.capture()
            : nil
        let userCacheProcessGuard = items.contains { $0.category == .userCaches }
            ? UserCacheProcessGuard.capture()
            : nil
        for item in items {
            if item.category == .heliumProfileCaches {
                guard UserCacheProcessGuard.permits(owner: heliumOwner, using: heliumProcessGuard),
                      heliumProfileCacheItemIsAllowed(item.path) else {
                    rejectedItems.append(CleanupRejectedItem(path: item.path, reason: .changed))
                    continue
                }
                validItems.append(item)
                continue
            }
            if item.category == .puppeteerCaches {
                guard puppeteerCacheItemIsAllowed(item.path) else {
                    rejectedItems.append(CleanupRejectedItem(path: item.path, reason: .changed))
                    continue
                }
                validItems.append(item)
                continue
            }
            if item.category == .edgeUpdaterOldVersions {
                guard edgeUpdaterOldVersionItemIsAllowed(item.path) else {
                    rejectedItems.append(CleanupRejectedItem(path: item.path, reason: .changed))
                    continue
                }
                validItems.append(item)
                continue
            }
            if item.category == .browserServiceWorkerCaches {
                guard browserServiceWorkerCacheItemIsAllowed(item.path) else {
                    rejectedItems.append(CleanupRejectedItem(path: item.path, reason: .changed))
                    continue
                }
                validItems.append(item)
                continue
            }
            if item.category == .browserOldVersions {
                guard browserOldVersionItemIsAllowed(item.path) else {
                    rejectedItems.append(CleanupRejectedItem(path: item.path, reason: .changed))
                    continue
                }
                validItems.append(item)
                continue
            }
            if item.category == .googleUpdaterCaches {
                guard googleUpdaterCacheItemIsAllowed(item.path) else {
                    rejectedItems.append(CleanupRejectedItem(path: item.path, reason: .changed))
                    continue
                }
                validItems.append(item)
                continue
            }
            if item.category == .qqBrowserProfileCaches {
                guard qqBrowserIsSafe,
                      qqBrowserProfileCacheItemIsAllowed(item.path) else {
                    rejectedItems.append(CleanupRejectedItem(path: item.path, reason: .changed))
                    continue
                }
                validItems.append(item)
                continue
            }
            if item.category == .vivaldiProfileCaches {
                guard vivaldiIsSafe,
                      vivaldiProfileCacheItemIsAllowed(item.path) else {
                    rejectedItems.append(CleanupRejectedItem(path: item.path, reason: .changed))
                    continue
                }
                validItems.append(item)
                continue
            }
            if item.category == .arcProfileCaches {
                guard arcIsSafe,
                      arcProfileCacheItemIsAllowed(item.path) else {
                    rejectedItems.append(CleanupRejectedItem(path: item.path, reason: .changed))
                    continue
                }
                validItems.append(item)
                continue
            }
            if item.category == .braveProfileCaches {
                guard braveIsSafe,
                      braveProfileCacheItemIsAllowed(item.path) else {
                    rejectedItems.append(CleanupRejectedItem(path: item.path, reason: .changed))
                    continue
                }
                validItems.append(item)
                continue
            }
            if item.category == .firefoxProfileCaches {
                guard firefoxIsSafe,
                      firefoxProfileCacheItemIsAllowed(item.path) else {
                    rejectedItems.append(CleanupRejectedItem(path: item.path, reason: .changed))
                    continue
                }
                validItems.append(item)
                continue
            }
            if item.category == .chromeProfileCaches {
                guard chromeIsSafe,
                      chromeProfileCacheItemIsAllowed(item.path) else {
                    rejectedItems.append(CleanupRejectedItem(path: item.path, reason: .changed))
                    continue
                }
                validItems.append(item)
                continue
            }
            if item.category == .diaProfileCaches {
                guard diaIsSafe,
                      diaProfileCacheItemIsAllowed(item.path) else {
                    rejectedItems.append(CleanupRejectedItem(path: item.path, reason: .changed))
                    continue
                }
                validItems.append(item)
                continue
            }
            if item.category == .userCaches,
               !UserCacheProcessGuard.permits(item.path, using: userCacheProcessGuard) {
                rejectedItems.append(CleanupRejectedItem(path: item.path, reason: .changed))
                continue
            }
            if item.category == .sharedContainerLogs {
                guard sharedContainerLogItemIsAllowed(item.path),
                      !holdsCompiledModelCache(item.path),
                      ContainerCacheSafety.isConclusivelyIdle(at: item.path) else {
                    rejectedItems.append(CleanupRejectedItem(path: item.path, reason: .changed))
                    continue
                }
                validItems.append(item)
                continue
            }
            if item.category == .virtualizationTemporaryData {
                guard virtualizationTemporaryItemIsAllowed(item.path) else {
                    rejectedItems.append(CleanupRejectedItem(path: item.path, reason: .changed))
                    continue
                }
                validItems.append(item)
                continue
            }
            if item.category == .addressBookPhotoCaches {
                guard addressBookPhotoCacheItemIsAllowed(item.path) else {
                    rejectedItems.append(CleanupRejectedItem(path: item.path, reason: .changed))
                    continue
                }
                validItems.append(item)
                continue
            }
            if item.category == .calendarCache {
                guard calendarCacheItemIsAllowed(item.path) else {
                    rejectedItems.append(CleanupRejectedItem(path: item.path, reason: .changed))
                    continue
                }
                validItems.append(item)
                continue
            }
            if item.category == .identityAndSuggestionCaches {
                guard identityAndSuggestionCacheItemIsAllowed(item.path) else {
                    rejectedItems.append(CleanupRejectedItem(path: item.path, reason: .changed))
                    continue
                }
                validItems.append(item)
                continue
            }
            if item.category == .utmCaches
                || (item.category == .userCaches && pathsEqual(item.path, utmApplicationCacheRoot())) {
                guard utmIsSafe,
                      item.category == .userCaches
                        || (utmCacheItemIsAllowed(item.path)
                            && ContainerCacheSafety.isConclusivelyIdle(at: item.path)) else {
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

    private static func scanVirtualizationTemporaryData() async -> (
        items: [CacheCleanupItem],
        unreadableItemCount: Int
    ) {
        var items: [CacheCleanupItem] = []
        var unreadableItemCount = 0

        let virtualBoxPath = virtualBoxCachePath()
        if FileManager.default.fileExists(atPath: virtualBoxPath) {
            if virtualizationTemporaryItemIsAllowed(virtualBoxPath),
               let measurement = await cacheTargetSize(at: virtualBoxPath) {
                items.append(CacheCleanupItem(
                    path: virtualBoxPath,
                    category: .virtualizationTemporaryData,
                    sizeBytes: measurement.sizeBytes
                ))
                unreadableItemCount += measurement.unreadableItemCount
            } else {
                unreadableItemCount += 1
            }
        }

        let vagrantRoot = vagrantTemporaryRoot()
        if isRealDirectory(at: vagrantRoot) {
            var finalUpdate: DiskAnalysisUpdate?
            for await update in DiskAnalyzer.updates(for: vagrantRoot) {
                guard !Task.isCancelled else { return ([], 0) }
                if update.isComplete { finalUpdate = update }
            }
            if let finalUpdate {
                unreadableItemCount += finalUpdate.unreadableItemCount
                items.append(contentsOf: finalUpdate.entrySizes.compactMap { path, size in
                    let name = URL(fileURLWithPath: path).lastPathComponent
                    guard !name.hasPrefix("."), virtualizationTemporaryItemIsAllowed(path) else {
                        return nil
                    }
                    return CacheCleanupItem(
                        path: path,
                        category: .virtualizationTemporaryData,
                        sizeBytes: size
                    )
                })
            } else {
                unreadableItemCount += 1
            }
        }

        return (items, unreadableItemCount)
    }

    private static func virtualizationTemporaryItemIsAllowed(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard !isSymbolicLink(at: url.path) else { return false }
        if pathsEqual(url.path, virtualBoxCachePath()) { return true }
        return !url.lastPathComponent.hasPrefix(".")
            && isRealDirectory(at: vagrantTemporaryRoot())
            && pathsEqual(url.deletingLastPathComponent().path, vagrantTemporaryRoot())
    }

    private static func virtualBoxCachePath() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("VirtualBox VMs", isDirectory: true)
            .appendingPathComponent(".cache")
            .standardizedFileURL.path
    }

    private static func vagrantTemporaryRoot() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".vagrant.d", isDirectory: true)
            .appendingPathComponent("tmp", isDirectory: true)
            .standardizedFileURL.path
    }

    private static func scanAddressBookPhotoCaches() async -> (
        items: [CacheCleanupItem],
        unreadableItemCount: Int
    ) {
        let rootPath = addressBookSourcesRoot()
        guard isRealDirectory(at: rootPath) else {
            return ([], FileManager.default.fileExists(atPath: rootPath) ? 1 : 0)
        }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        let sourceURLs: [URL]
        do {
            sourceURLs = try FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
        } catch {
            return ([], 1)
        }

        var items: [CacheCleanupItem] = []
        var unreadableItemCount = 0
        for sourceURL in sourceURLs where !sourceURL.lastPathComponent.hasPrefix(".") {
            guard !Task.isCancelled else { return ([], 0) }
            guard isRealDirectory(at: sourceURL.path) else { continue }
            let candidate = sourceURL.appendingPathComponent("Photos.cache").standardizedFileURL.path
            guard FileManager.default.fileExists(atPath: candidate) else { continue }
            guard addressBookPhotoCacheItemIsAllowed(candidate),
                  let measurement = await cacheTargetSize(at: candidate) else {
                unreadableItemCount += 1
                continue
            }
            unreadableItemCount += measurement.unreadableItemCount
            items.append(CacheCleanupItem(
                path: candidate,
                category: .addressBookPhotoCaches,
                sizeBytes: measurement.sizeBytes
            ))
        }
        return (items, unreadableItemCount)
    }

    private static func addressBookPhotoCacheItemIsAllowed(_ path: String) -> Bool {
        let root = addressBookSourcesRoot()
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let source = url.deletingLastPathComponent()
        return url.lastPathComponent == "Photos.cache"
            && !source.lastPathComponent.hasPrefix(".")
            && isRealDirectory(at: root)
            && isRealDirectory(at: source.path)
            && pathsEqual(source.deletingLastPathComponent().path, root)
            && !isSymbolicLink(at: url.path)
    }

    private static func addressBookSourcesRoot() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AddressBook/Sources", isDirectory: true)
            .standardizedFileURL.path
    }

    private static func scanCalendarCache() async -> (
        items: [CacheCleanupItem],
        unreadableItemCount: Int
    ) {
        let path = calendarCachePath()
        guard FileManager.default.fileExists(atPath: path) else { return ([], 0) }
        guard calendarCacheItemIsAllowed(path),
              let measurement = await cacheTargetSize(at: path) else {
            return ([], 1)
        }
        return ([CacheCleanupItem(
            path: path,
            category: .calendarCache,
            sizeBytes: measurement.sizeBytes
        )], measurement.unreadableItemCount)
    }

    private static func cacheTargetSize(at path: String) async -> (
        sizeBytes: UInt64,
        unreadableItemCount: Int
    )? {
        var value = stat()
        guard path.withCString({ lstat($0, &value) }) == 0 else { return nil }
        let kind = value.st_mode & S_IFMT
        if kind == S_IFREG {
            let size = value.st_blocks > 0 ? UInt64(value.st_blocks) * 512 : 0
            return (size, 0)
        }
        guard kind == S_IFDIR else { return nil }
        var finalUpdate: DiskAnalysisUpdate?
        for await update in DiskAnalyzer.updates(for: path) {
            guard !Task.isCancelled else { return nil }
            if update.isComplete { finalUpdate = update }
        }
        guard let finalUpdate else { return nil }
        return (finalUpdate.scannedBytes, finalUpdate.unreadableItemCount)
    }

    private static func calendarCacheItemIsAllowed(_ path: String) -> Bool {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        return pathsEqual(normalized, calendarCachePath())
            && !isSymbolicLink(at: normalized)
    }

    private static func calendarCachePath() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Calendars", isDirectory: true)
            .appendingPathComponent("Calendar Cache")
            .standardizedFileURL.path
    }

    private static func scanIdentityAndSuggestionCaches() async -> (
        items: [CacheCleanupItem],
        unreadableItemCount: Int
    ) {
        var items: [CacheCleanupItem] = []
        var unreadableItemCount = 0
        for rootPath in identityAndSuggestionCacheRoots() where isRealDirectory(at: rootPath) {
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
                guard !name.hasPrefix("."), identityAndSuggestionCacheItemIsAllowed(path) else {
                    return nil
                }
                return CacheCleanupItem(
                    path: path,
                    category: .identityAndSuggestionCaches,
                    sizeBytes: size
                )
            })
        }
        return (items, unreadableItemCount)
    }

    private static func identityAndSuggestionCacheItemIsAllowed(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard !url.lastPathComponent.hasPrefix("."),
              !isSymbolicLink(at: url.path) else {
            return false
        }
        return identityAndSuggestionCacheRoots().contains { root in
            isRealDirectory(at: root)
                && pathsEqual(url.deletingLastPathComponent().path, root)
        }
    }

    private static func identityAndSuggestionCacheRoots() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        return [
            home + "/Library/IdentityCaches",
            home + "/Library/Suggestions"
        ]
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
                guard !name.hasPrefix("."),
                      utmCacheItemIsAllowed(path),
                      ContainerCacheSafety.isConclusivelyIdle(at: path) else {
                    return nil
                }
                return CacheCleanupItem(path: path, category: .utmCaches, sizeBytes: size)
            })
        }
        return (items, unreadableItemCount)
    }

    private static func scanDiaProfileCaches() async -> (
        items: [CacheCleanupItem],
        unreadableItemCount: Int
    ) {
        var items: [CacheCleanupItem] = []
        var unreadableItemCount = 0
        for root in diaProfileCacheRoots() where isRealDirectory(at: root) {
            var finalUpdate: DiskAnalysisUpdate?
            for await update in DiskAnalyzer.updates(for: root) {
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
                guard !name.hasPrefix("."), diaProfileCacheItemIsAllowed(path) else {
                    return nil
                }
                return CacheCleanupItem(
                    path: path,
                    category: .diaProfileCaches,
                    sizeBytes: size
                )
            })
        }
        return (items, unreadableItemCount)
    }

    private static func diaProfileCacheItemIsAllowed(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard !url.lastPathComponent.hasPrefix("."),
              !isSymbolicLink(at: url.path),
              !holdsCompiledModelCache(url.path) else {
            return false
        }
        return diaProfileCacheRoots().contains { root in
            isRealDirectory(at: root)
                && pathsEqual(url.deletingLastPathComponent().path, root)
        }
    }

    private static func diaProfileCacheRoots() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let cacheUserData = home + "/Library/Caches/Dia/User Data"
        let supportUserData = home + "/Library/Application Support/Dia/User Data"
        var roots = [
            supportUserData + "/GraphiteDawnCache",
            supportUserData + "/GPUPersistentCache",
            supportUserData + "/component_crx_cache",
            supportUserData + "/extensions_crx_cache"
        ]
        roots.append(contentsOf: childDirectories(at: cacheUserData).flatMap { profile in
            [profile + "/Cache", profile + "/Code Cache"]
        })
        roots.append(contentsOf: childDirectories(at: supportUserData).flatMap { profile in
            [
                profile + "/DawnGraphiteCache",
                profile + "/DawnWebGPUCache",
                profile + "/GPUCache"
            ]
        })
        var seen: Set<String> = []
        return roots.filter { seen.insert($0).inserted }
    }

    private static func childDirectories(at path: String) -> [String] {
        guard isRealDirectory(at: path),
              let urls = try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: path, isDirectory: true),
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true,
                  values.isSymbolicLink != true else {
                return nil
            }
            return url.standardizedFileURL.path
        }
    }

    private static func diaGeneralCacheRoot() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/Dia", isDirectory: true)
            .standardizedFileURL.path
    }

    private static func googleGeneralCacheRoot() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/Google", isDirectory: true)
            .standardizedFileURL.path
    }

    private static func firefoxGeneralCacheRoot() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/Firefox", isDirectory: true)
            .standardizedFileURL.path
    }

    private static func braveGeneralCacheRoot() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/BraveSoftware", isDirectory: true)
            .standardizedFileURL.path
    }

    private static func arcGeneralCacheRoot() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/company.thebrowser.Browser", isDirectory: true)
            .standardizedFileURL.path
    }

    private static func vivaldiGeneralCacheRoot() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/com.vivaldi.Vivaldi", isDirectory: true)
            .standardizedFileURL.path
    }

    private static func qqBrowserGeneralCacheRoot() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/com.tencent.QQBrowser3", isDirectory: true)
            .standardizedFileURL.path
    }

    private static func heliumGeneralCacheRoot() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/net.imput.helium", isDirectory: true)
            .standardizedFileURL.path
    }

    private static func diaIsInactive() -> Bool {
        processProbesAreInactive([["-x", "Dia"]])
    }

    private static func scanChromeProfileCaches() async -> (
        items: [CacheCleanupItem],
        unreadableItemCount: Int
    ) {
        var items: [CacheCleanupItem] = []
        var unreadableItemCount = 0
        for root in chromeProfileCacheRoots() where isRealDirectory(at: root) {
            var finalUpdate: DiskAnalysisUpdate?
            for await update in DiskAnalyzer.updates(for: root) {
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
                guard !name.hasPrefix("."), chromeProfileCacheItemIsAllowed(path) else {
                    return nil
                }
                return CacheCleanupItem(
                    path: path,
                    category: .chromeProfileCaches,
                    sizeBytes: size
                )
            })
        }
        return (items, unreadableItemCount)
    }

    private static func scanFirefoxProfileCaches() async -> (
        items: [CacheCleanupItem],
        unreadableItemCount: Int
    ) {
        var items: [CacheCleanupItem] = []
        var unreadableItemCount = 0
        for root in firefoxProfileCacheRoots() where isRealDirectory(at: root) {
            var finalUpdate: DiskAnalysisUpdate?
            for await update in DiskAnalyzer.updates(for: root) {
                guard !Task.isCancelled else { return ([], 0) }
                if update.isComplete { finalUpdate = update }
            }
            guard let finalUpdate else {
                unreadableItemCount += 1
                continue
            }
            unreadableItemCount += finalUpdate.unreadableItemCount
            items.append(contentsOf: finalUpdate.entrySizes.compactMap { path, size in
                guard firefoxProfileCacheItemIsAllowed(path) else { return nil }
                return CacheCleanupItem(
                    path: path,
                    category: .firefoxProfileCaches,
                    sizeBytes: size
                )
            })
        }
        return (items, unreadableItemCount)
    }

    private static func scanBraveProfileCaches() async -> (
        items: [CacheCleanupItem],
        unreadableItemCount: Int
    ) {
        var items: [CacheCleanupItem] = []
        var unreadableItemCount = 0
        for root in braveProfileCacheRoots() where isRealDirectory(at: root) {
            var finalUpdate: DiskAnalysisUpdate?
            for await update in DiskAnalyzer.updates(for: root) {
                guard !Task.isCancelled else { return ([], 0) }
                if update.isComplete { finalUpdate = update }
            }
            guard let finalUpdate else {
                unreadableItemCount += 1
                continue
            }
            unreadableItemCount += finalUpdate.unreadableItemCount
            items.append(contentsOf: finalUpdate.entrySizes.compactMap { path, size in
                guard braveProfileCacheItemIsAllowed(path) else { return nil }
                return CacheCleanupItem(
                    path: path,
                    category: .braveProfileCaches,
                    sizeBytes: size
                )
            })
        }
        return (items, unreadableItemCount)
    }

    private static func scanArcProfileCaches() async -> (
        items: [CacheCleanupItem],
        unreadableItemCount: Int
    ) {
        var items: [CacheCleanupItem] = []
        var unreadableItemCount = 0
        for root in arcProfileCacheRoots() where isRealDirectory(at: root) {
            var finalUpdate: DiskAnalysisUpdate?
            for await update in DiskAnalyzer.updates(for: root) {
                guard !Task.isCancelled else { return ([], 0) }
                if update.isComplete { finalUpdate = update }
            }
            guard let finalUpdate else {
                unreadableItemCount += 1
                continue
            }
            unreadableItemCount += finalUpdate.unreadableItemCount
            items.append(contentsOf: finalUpdate.entrySizes.compactMap { path, size in
                guard arcProfileCacheItemIsAllowed(path) else { return nil }
                return CacheCleanupItem(
                    path: path,
                    category: .arcProfileCaches,
                    sizeBytes: size
                )
            })
        }
        return (items, unreadableItemCount)
    }

    private static func scanVivaldiProfileCaches() async -> (
        items: [CacheCleanupItem],
        unreadableItemCount: Int
    ) {
        var items: [CacheCleanupItem] = []
        var unreadableItemCount = 0
        for root in vivaldiProfileCacheRoots() where isRealDirectory(at: root) {
            var finalUpdate: DiskAnalysisUpdate?
            for await update in DiskAnalyzer.updates(for: root) {
                guard !Task.isCancelled else { return ([], 0) }
                if update.isComplete { finalUpdate = update }
            }
            guard let finalUpdate else {
                unreadableItemCount += 1
                continue
            }
            unreadableItemCount += finalUpdate.unreadableItemCount
            items.append(contentsOf: finalUpdate.entrySizes.compactMap { path, size in
                guard vivaldiProfileCacheItemIsAllowed(path) else { return nil }
                return CacheCleanupItem(
                    path: path,
                    category: .vivaldiProfileCaches,
                    sizeBytes: size
                )
            })
        }
        return (items, unreadableItemCount)
    }

    private static func scanQQBrowserProfileCaches() async -> (
        items: [CacheCleanupItem],
        unreadableItemCount: Int
    ) {
        var items: [CacheCleanupItem] = []
        var unreadableItemCount = 0
        for root in qqBrowserProfileCacheRoots() where isRealDirectory(at: root) {
            var finalUpdate: DiskAnalysisUpdate?
            for await update in DiskAnalyzer.updates(for: root) {
                guard !Task.isCancelled else { return ([], 0) }
                if update.isComplete { finalUpdate = update }
            }
            guard let finalUpdate else {
                unreadableItemCount += 1
                continue
            }
            unreadableItemCount += finalUpdate.unreadableItemCount
            items.append(contentsOf: finalUpdate.entrySizes.compactMap { path, size in
                guard qqBrowserProfileCacheItemIsAllowed(path) else { return nil }
                return CacheCleanupItem(
                    path: path,
                    category: .qqBrowserProfileCaches,
                    sizeBytes: size
                )
            })
        }
        return (items, unreadableItemCount)
    }

    private static func scanPuppeteerCaches() async -> (
        items: [CacheCleanupItem],
        unreadableItemCount: Int
    ) {
        let root = puppeteerCacheRoot()
        guard isRealDirectory(at: root) else { return ([], 0) }
        var finalUpdate: DiskAnalysisUpdate?
        for await update in DiskAnalyzer.updates(for: root) {
            guard !Task.isCancelled else { return ([], 0) }
            if update.isComplete { finalUpdate = update }
        }
        guard let finalUpdate else { return ([], 1) }
        let items: [CacheCleanupItem] = finalUpdate.entrySizes.compactMap { path, size in
            guard puppeteerCacheItemIsAllowed(path) else { return nil }
            return CacheCleanupItem(
                path: path,
                category: .puppeteerCaches,
                sizeBytes: size
            )
        }
        return (items, finalUpdate.unreadableItemCount)
    }

    private static func scanHeliumProfileCaches() async -> (
        items: [CacheCleanupItem],
        unreadableItemCount: Int
    ) {
        var items: [CacheCleanupItem] = []
        var unreadableItemCount = 0
        for root in heliumProfileCacheRoots() where isRealDirectory(at: root) {
            var finalUpdate: DiskAnalysisUpdate?
            for await update in DiskAnalyzer.updates(for: root) {
                guard !Task.isCancelled else { return ([], 0) }
                if update.isComplete { finalUpdate = update }
            }
            guard let finalUpdate else {
                unreadableItemCount += 1
                continue
            }
            unreadableItemCount += finalUpdate.unreadableItemCount
            items.append(contentsOf: finalUpdate.entrySizes.compactMap { path, size in
                guard heliumProfileCacheItemIsAllowed(path) else { return nil }
                return CacheCleanupItem(
                    path: path,
                    category: .heliumProfileCaches,
                    sizeBytes: size
                )
            })
        }
        return (items, unreadableItemCount)
    }

    private static func scanBrowserServiceWorkerCaches() async -> (
        items: [CacheCleanupItem],
        unreadableItemCount: Int
    ) {
        var items: [CacheCleanupItem] = []
        var unreadableItemCount = 0
        for source in browserServiceWorkerSources() {
            guard processProbesAreInactive(source.processProbes) else { continue }
            var sourceItems: [CacheCleanupItem] = []
            var sourceIsSafe = true
            for root in source.cacheRoots where isRealDirectory(at: root) {
                for firstLevel in childDirectories(at: root) {
                    for path in childDirectories(at: firstLevel) {
                        guard !Task.isCancelled else { return ([], 0) }
                        guard processProbesAreInactive(source.processProbes) else {
                            sourceIsSafe = false
                            break
                        }
                        guard !serviceWorkerCacheNameIsProtected(path) else { continue }
                        var finalUpdate: DiskAnalysisUpdate?
                        for await update in DiskAnalyzer.updates(for: path) {
                            guard !Task.isCancelled else { return ([], 0) }
                            if update.isComplete { finalUpdate = update }
                        }
                        guard let finalUpdate else {
                            unreadableItemCount += 1
                            continue
                        }
                        unreadableItemCount += finalUpdate.unreadableItemCount
                        guard processProbesAreInactive(source.processProbes) else {
                            sourceIsSafe = false
                            break
                        }
                        sourceItems.append(CacheCleanupItem(
                            path: path,
                            category: .browserServiceWorkerCaches,
                            sizeBytes: finalUpdate.scannedBytes
                        ))
                    }
                    if !sourceIsSafe { break }
                }
                if !sourceIsSafe { break }
            }
            if sourceIsSafe {
                items.append(contentsOf: sourceItems)
            }
        }
        return (items, unreadableItemCount)
    }

    private static func scanBrowserOldVersions() async -> (
        items: [CacheCleanupItem],
        unreadableItemCount: Int
    ) {
        var items: [CacheCleanupItem] = []
        var unreadableItemCount = 0
        for source in chromiumVersionSources() {
            guard processProbesAreInactive(source.processProbes) else { continue }
            var sourceItems: [CacheCleanupItem] = []
            var sourceIsSafe = true
            for appPath in source.appPaths {
                let versionsRoot = appPath
                    + "/Contents/Frameworks/"
                    + source.frameworkName
                    + "/Versions"
                for path in browserOldVersionDirectories(in: versionsRoot) {
                    guard !Task.isCancelled else { return ([], 0) }
                    guard processProbesAreInactive(source.processProbes) else {
                        sourceIsSafe = false
                        break
                    }
                    var finalUpdate: DiskAnalysisUpdate?
                    for await update in DiskAnalyzer.updates(for: path) {
                        guard !Task.isCancelled else { return ([], 0) }
                        if update.isComplete { finalUpdate = update }
                    }
                    guard let finalUpdate else {
                        unreadableItemCount += 1
                        continue
                    }
                    unreadableItemCount += finalUpdate.unreadableItemCount
                    guard processProbesAreInactive(source.processProbes) else {
                        sourceIsSafe = false
                        break
                    }
                    sourceItems.append(CacheCleanupItem(
                        path: path,
                        category: .browserOldVersions,
                        sizeBytes: finalUpdate.scannedBytes
                    ))
                }
                if !sourceIsSafe { break }
            }
            if sourceIsSafe {
                items.append(contentsOf: sourceItems)
            }
        }
        return (items, unreadableItemCount)
    }

    private static func scanEdgeUpdaterOldVersions() async -> (
        items: [CacheCleanupItem],
        unreadableItemCount: Int
    ) {
        guard edgeIsInactive() else { return ([], 0) }
        var items: [CacheCleanupItem] = []
        var unreadableItemCount = 0
        for path in edgeUpdaterOldVersionDirectories() {
            guard !Task.isCancelled else { return ([], 0) }
            guard edgeIsInactive() else { return ([], unreadableItemCount) }
            var finalUpdate: DiskAnalysisUpdate?
            for await update in DiskAnalyzer.updates(for: path) {
                guard !Task.isCancelled else { return ([], 0) }
                if update.isComplete { finalUpdate = update }
            }
            guard let finalUpdate else {
                unreadableItemCount += 1
                continue
            }
            unreadableItemCount += finalUpdate.unreadableItemCount
            guard edgeIsInactive() else { return ([], unreadableItemCount) }
            items.append(CacheCleanupItem(
                path: path,
                category: .edgeUpdaterOldVersions,
                sizeBytes: finalUpdate.scannedBytes
            ))
        }
        return (items, unreadableItemCount)
    }

    private static func scanGoogleUpdaterCaches() async -> (
        items: [CacheCleanupItem],
        unreadableItemCount: Int
    ) {
        var items: [CacheCleanupItem] = []
        var unreadableItemCount = 0
        let crxRoot = googleUpdaterRoot() + "/crx_cache"
        if isRealDirectory(at: crxRoot) {
            var finalUpdate: DiskAnalysisUpdate?
            for await update in DiskAnalyzer.updates(for: crxRoot) {
                guard !Task.isCancelled else { return ([], 0) }
                if update.isComplete { finalUpdate = update }
            }
            if let finalUpdate {
                unreadableItemCount += finalUpdate.unreadableItemCount
                items.append(contentsOf: finalUpdate.entrySizes.compactMap { path, size in
                    guard googleUpdaterCacheItemIsAllowed(path) else { return nil }
                    return CacheCleanupItem(
                        path: path,
                        category: .googleUpdaterCaches,
                        sizeBytes: size
                    )
                })
            } else {
                unreadableItemCount += 1
            }
        }

        for path in googleUpdaterOldFiles() {
            guard !Task.isCancelled else { return ([], 0) }
            guard googleUpdaterCacheItemIsAllowed(path),
                  let size = cacheFileSize(at: path) else {
                unreadableItemCount += 1
                continue
            }
            items.append(CacheCleanupItem(
                path: path,
                category: .googleUpdaterCaches,
                sizeBytes: size
            ))
        }
        return (items, unreadableItemCount)
    }

    private static func googleUpdaterCacheItemIsAllowed(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard !url.lastPathComponent.hasPrefix("."),
              !isSymbolicLink(at: url.path) else {
            return false
        }
        let root = googleUpdaterRoot()
        let parent = url.deletingLastPathComponent().path
        if pathsEqual(parent, root + "/crx_cache") {
            return isRealDirectory(at: parent) && !holdsCompiledModelCache(url.path)
        }
        return pathsEqual(parent, root)
            && url.pathExtension.lowercased() == "old"
            && cacheFileSize(at: url.path) != nil
    }

    private static func googleUpdaterOldFiles() -> [String] {
        let root = googleUpdaterRoot()
        guard isRealDirectory(at: root),
              let urls = try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: root, isDirectory: true),
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }
        return urls
            .filter { $0.pathExtension.lowercased() == "old" }
            .map { $0.standardizedFileURL.path }
    }

    private static func googleUpdaterRoot() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/GoogleUpdater", isDirectory: true)
            .standardizedFileURL.path
    }

    private static func cacheFileSize(at path: String) -> UInt64? {
        var value = stat()
        guard path.withCString({ lstat($0, &value) }) == 0,
              value.st_mode & S_IFMT == S_IFREG else {
            return nil
        }
        return value.st_blocks > 0 ? UInt64(value.st_blocks) * 512 : 0
    }

    private static func chromeProfileCacheItemIsAllowed(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard !url.lastPathComponent.hasPrefix("."),
              !isSymbolicLink(at: url.path),
              !holdsCompiledModelCache(url.path) else {
            return false
        }
        return chromeProfileCacheRoots().contains { root in
            isRealDirectory(at: root)
                && pathsEqual(url.deletingLastPathComponent().path, root)
        }
    }

    private static func chromeProfileCacheRoots() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let chromeCaches = home + "/Library/Caches/Google/Chrome"
        let chromeSupport = home + "/Library/Application Support/Google/Chrome"
        var roots = [
            chromeCaches,
            chromeSupport + "/component_crx_cache",
            chromeSupport + "/ShaderCache",
            chromeSupport + "/GrShaderCache",
            chromeSupport + "/GraphiteDawnCache",
            chromeSupport + "/Crashpad/completed",
            chromeSupport + "/OptGuideOnDeviceModel",
            chromeSupport + "/OptGuideOnDeviceClassifierModel",
            chromeSupport + "/optimization_guide_model_store"
        ]
        roots.append(contentsOf: childDirectories(at: chromeSupport).flatMap { profile in
            [
                profile + "/Application Cache",
                profile + "/Code Cache",
                profile + "/GPUCache",
                profile + "/DawnCache",
                profile + "/GrShaderCache",
                profile + "/GraphiteDawnCache"
            ]
        })
        var seen: Set<String> = []
        return roots.filter { seen.insert($0).inserted }
    }

    private static func firefoxProfileCacheItemIsAllowed(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard !url.lastPathComponent.hasPrefix("."),
              !isSymbolicLink(at: url.path),
              !holdsCompiledModelCache(url.path) else {
            return false
        }
        return firefoxProfileCacheRoots().contains { root in
            isRealDirectory(at: root)
                && pathsEqual(url.deletingLastPathComponent().path, root)
        }
    }

    private static func firefoxProfileCacheRoots() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let profiles = home + "/Library/Application Support/Firefox/Profiles"
        return [firefoxGeneralCacheRoot()] + childDirectories(at: profiles).map { profile in
            profile + "/cache2"
        }
    }

    private static func braveProfileCacheItemIsAllowed(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard !url.lastPathComponent.hasPrefix("."),
              !isSymbolicLink(at: url.path),
              !holdsCompiledModelCache(url.path) else {
            return false
        }
        return braveProfileCacheRoots().contains { root in
            isRealDirectory(at: root)
                && pathsEqual(url.deletingLastPathComponent().path, root)
        }
    }

    private static func braveProfileCacheRoots() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let cacheRoot = home + "/Library/Caches/BraveSoftware/Brave-Browser"
        let supportRoot = home + "/Library/Application Support/BraveSoftware/Brave-Browser"
        var roots = [
            cacheRoot,
            supportRoot + "/component_crx_cache",
            supportRoot + "/ShaderCache",
            supportRoot + "/GrShaderCache",
            supportRoot + "/GraphiteDawnCache",
            supportRoot + "/Crashpad/completed"
        ]
        roots.append(contentsOf: childDirectories(at: supportRoot).flatMap { profile in
            [
                profile + "/Application Cache",
                profile + "/Code Cache",
                profile + "/GPUCache",
                profile + "/DawnCache",
                profile + "/GrShaderCache",
                profile + "/GraphiteDawnCache"
            ]
        })
        var seen: Set<String> = []
        return roots.filter { seen.insert($0).inserted }
    }

    private static func arcProfileCacheItemIsAllowed(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard !url.lastPathComponent.hasPrefix("."),
              !isSymbolicLink(at: url.path),
              !holdsCompiledModelCache(url.path) else {
            return false
        }
        return arcProfileCacheRoots().contains { root in
            isRealDirectory(at: root)
                && pathsEqual(url.deletingLastPathComponent().path, root)
        }
    }

    private static func arcProfileCacheRoots() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let supportRoot = home + "/Library/Application Support/Arc"
        let userDataRoot = supportRoot + "/User Data"
        var roots = [
            arcGeneralCacheRoot(),
            supportRoot + "/ShaderCache",
            supportRoot + "/GrShaderCache",
            supportRoot + "/GraphiteDawnCache",
            supportRoot + "/Crashpad/completed",
            userDataRoot + "/ShaderCache",
            userDataRoot + "/GrShaderCache",
            userDataRoot + "/GraphiteDawnCache",
            userDataRoot + "/component_crx_cache",
            userDataRoot + "/extensions_crx_cache",
            userDataRoot + "/Crashpad/completed"
        ]
        roots.append(contentsOf: childDirectories(at: supportRoot).flatMap { profile in
            arcProfileCacheDirectories(at: profile)
        })
        roots.append(contentsOf: childDirectories(at: userDataRoot).flatMap { profile in
            arcProfileCacheDirectories(at: profile)
        })
        var seen: Set<String> = []
        return roots.filter { seen.insert($0).inserted }
    }

    private static func arcProfileCacheDirectories(at profile: String) -> [String] {
        [
            profile + "/Code Cache",
            profile + "/GPUCache",
            profile + "/DawnCache",
            profile + "/GrShaderCache",
            profile + "/GraphiteDawnCache"
        ]
    }

    private static func vivaldiProfileCacheItemIsAllowed(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard !url.lastPathComponent.hasPrefix("."),
              !isSymbolicLink(at: url.path),
              !holdsCompiledModelCache(url.path) else {
            return false
        }
        return vivaldiProfileCacheRoots().contains { root in
            isRealDirectory(at: root)
                && pathsEqual(url.deletingLastPathComponent().path, root)
        }
    }

    private static func vivaldiProfileCacheRoots() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let supportRoot = home + "/Library/Application Support/Vivaldi"
        var roots = [
            vivaldiGeneralCacheRoot(),
            supportRoot + "/ShaderCache",
            supportRoot + "/GrShaderCache",
            supportRoot + "/GraphiteDawnCache",
            supportRoot + "/Crashpad/completed"
        ]
        roots.append(contentsOf: childDirectories(at: supportRoot).flatMap { profile in
            [
                profile + "/Code Cache",
                profile + "/GPUCache",
                profile + "/DawnCache",
                profile + "/GrShaderCache",
                profile + "/GraphiteDawnCache"
            ]
        })
        var seen: Set<String> = []
        return roots.filter { seen.insert($0).inserted }
    }

    private static func qqBrowserProfileCacheItemIsAllowed(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard !url.lastPathComponent.hasPrefix("."),
              !isSymbolicLink(at: url.path),
              !holdsCompiledModelCache(url.path) else {
            return false
        }
        return qqBrowserProfileCacheRoots().contains { root in
            isRealDirectory(at: root)
                && pathsEqual(url.deletingLastPathComponent().path, root)
        }
    }

    private static func qqBrowserProfileCacheRoots() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let supportRoot = home + "/Library/Application Support/QQBrowser3"
        var roots = [
            qqBrowserGeneralCacheRoot(),
            supportRoot + "/ShaderCache",
            supportRoot + "/GrShaderCache",
            supportRoot + "/GraphiteDawnCache",
            supportRoot + "/component_crx_cache",
            supportRoot + "/Crashpad/completed"
        ]
        roots.append(contentsOf: childDirectories(at: supportRoot).flatMap { profile in
            [
                profile + "/Code Cache",
                profile + "/GPUCache"
            ]
        })
        var seen: Set<String> = []
        return roots.filter { seen.insert($0).inserted }
    }

    private static func puppeteerCacheItemIsAllowed(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let root = puppeteerCacheRoot()
        guard !url.lastPathComponent.hasPrefix("."),
              !isSymbolicLink(at: url.path),
              isRealFileOrDirectory(at: url.path),
              !holdsCompiledModelCache(url.path),
              isRealDirectory(at: root),
              pathsEqual(url.deletingLastPathComponent().path, root) else {
            return false
        }
        return true
    }

    private static func puppeteerCacheRoot() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/puppeteer", isDirectory: true)
            .standardizedFileURL.path
    }

    private static let heliumOwner = "net.imput.helium"

    private static func heliumProfileCacheItemIsAllowed(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard !url.lastPathComponent.hasPrefix("."),
              !isSymbolicLink(at: url.path),
              !holdsCompiledModelCache(url.path) else {
            return false
        }
        return heliumProfileCacheRoots().contains { root in
            isRealDirectory(at: root)
                && pathsEqual(url.deletingLastPathComponent().path, root)
        }
    }

    private static func heliumProfileCacheRoots() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let supportRoot = home + "/Library/Application Support/net.imput.helium"
        var roots = [
            heliumGeneralCacheRoot(),
            supportRoot + "/component_crx_cache",
            supportRoot + "/extensions_crx_cache",
            supportRoot + "/GrShaderCache",
            supportRoot + "/GraphiteDawnCache",
            supportRoot + "/ShaderCache"
        ]
        roots.append(contentsOf: childDirectories(at: supportRoot).flatMap { profile in
            [
                profile + "/GPUCache",
                profile + "/Application Cache"
            ]
        })
        var seen: Set<String> = []
        return roots.filter { seen.insert($0).inserted }
    }

    private static func browserServiceWorkerSources() -> [BrowserServiceWorkerSource] {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let chrome = home + "/Library/Application Support/Google/Chrome"
        let arc = home + "/Library/Application Support/Arc"
        let arcUserData = arc + "/User Data"
        let dia = home + "/Library/Application Support/Dia/User Data"
        let brave = home + "/Library/Application Support/BraveSoftware/Brave-Browser"
        let vivaldi = home + "/Library/Application Support/Vivaldi"
        return [
            BrowserServiceWorkerSource(
                cacheRoots: serviceWorkerCacheRoots(in: childDirectories(at: chrome)),
                processProbes: [
                    ["-x", "Google Chrome"],
                    ["-x", "Google Chrome Helper"],
                    ["-f", "/Google Chrome.app/"]
                ]
            ),
            BrowserServiceWorkerSource(
                cacheRoots: serviceWorkerCacheRoots(
                    in: childDirectories(at: arc) + childDirectories(at: arcUserData)
                ),
                processProbes: [["-x", "Arc"]]
            ),
            BrowserServiceWorkerSource(
                cacheRoots: serviceWorkerCacheRoots(in: childDirectories(at: dia)),
                processProbes: [["-x", "Dia"]]
            ),
            BrowserServiceWorkerSource(
                cacheRoots: serviceWorkerCacheRoots(in: childDirectories(at: brave)),
                processProbes: [["-x", "Brave Browser"]]
            ),
            BrowserServiceWorkerSource(
                cacheRoots: serviceWorkerCacheRoots(in: childDirectories(at: vivaldi)),
                processProbes: [["-x", "Vivaldi"]]
            )
        ]
    }

    private static func serviceWorkerCacheRoots(in profiles: [String]) -> [String] {
        var seen: Set<String> = []
        return profiles
            .map { $0 + "/Service Worker/CacheStorage" }
            .filter { seen.insert($0).inserted }
    }

    private static func browserServiceWorkerCacheItemIsAllowed(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let firstLevel = url.deletingLastPathComponent()
        let cacheRoot = firstLevel.deletingLastPathComponent().standardizedFileURL.path
        guard !url.lastPathComponent.hasPrefix("."),
              !isSymbolicLink(at: url.path),
              isRealDirectory(at: url.path),
              !holdsCompiledModelCache(url.path),
              !serviceWorkerCacheNameIsProtected(url.path),
              let source = browserServiceWorkerSources().first(where: { source in
                  source.cacheRoots.contains { pathsEqual($0, cacheRoot) }
              }),
              processProbesAreInactive(source.processProbes),
              childDirectories(at: cacheRoot).contains(where: { pathsEqual($0, firstLevel.path) }),
              childDirectories(at: firstLevel.path).contains(where: { pathsEqual($0, url.path) }) else {
            return false
        }
        return true
    }

    private static func serviceWorkerCacheNameIsProtected(_ path: String) -> Bool {
        let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        guard let range = name.range(
            of: #"[a-z0-9][-a-z0-9]*\.[a-z]{2,}"#,
            options: .regularExpression
        ) else {
            return false
        }
        let domain = String(name[range])
        return protectedServiceWorkerDomains.contains { domain.contains($0) }
    }

    private static let protectedServiceWorkerDomains = [
        "capcut.com",
        "photopea.com",
        "pixlr.com",
        "docs.google.com",
        "sheets.google.com",
        "slides.google.com",
        "drive.google.com",
        "mail.google.com",
        "github.com",
        "gitlab.com",
        "codepen.io",
        "codesandbox.io",
        "replit.com",
        "stackblitz.com",
        "notion.so",
        "figma.com",
        "linear.app",
        "excalidraw.com"
    ]

    private static func chromiumVersionSources() -> [ChromiumVersionSource] {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        return [
            ChromiumVersionSource(
                appPaths: [
                    "/Applications/Google Chrome.app",
                    home + "/Applications/Google Chrome.app"
                ],
                frameworkName: "Google Chrome Framework.framework",
                processProbes: [
                    ["-x", "Google Chrome"],
                    ["-x", "Google Chrome Helper"],
                    ["-f", "/Google Chrome.app/"]
                ]
            ),
            ChromiumVersionSource(
                appPaths: [
                    "/Applications/Microsoft Edge.app",
                    home + "/Applications/Microsoft Edge.app"
                ],
                frameworkName: "Microsoft Edge Framework.framework",
                processProbes: [["-x", "Microsoft Edge"]]
            ),
            ChromiumVersionSource(
                appPaths: [
                    "/Applications/Brave Browser.app",
                    home + "/Applications/Brave Browser.app"
                ],
                frameworkName: "Brave Browser Framework.framework",
                processProbes: [["-x", "Brave Browser"]]
            )
        ]
    }

    private static func browserOldVersionItemIsAllowed(_ path: String) -> Bool {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard !isSymbolicLink(at: normalized),
              isRealDirectory(at: normalized),
              !holdsCompiledModelCache(normalized),
              let source = browserVersionSource(containing: normalized),
              processProbesAreInactive(source.processProbes) else {
            return false
        }
        let versionsRoot = URL(fileURLWithPath: normalized)
            .deletingLastPathComponent()
            .standardizedFileURL.path
        return browserOldVersionDirectories(in: versionsRoot).contains {
            pathsEqual($0, normalized)
        }
    }

    private static func browserVersionSource(containing path: String) -> ChromiumVersionSource? {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL.path
        for source in chromiumVersionSources() {
            for appPath in source.appPaths {
                let versionsRoot = appPath
                    + "/Contents/Frameworks/"
                    + source.frameworkName
                    + "/Versions"
                if pathsEqual(parent, versionsRoot) {
                    return source
                }
            }
        }
        return nil
    }

    private static func browserOldVersionDirectories(in versionsRoot: String) -> [String] {
        let currentLink = versionsRoot + "/Current"
        guard isRealDirectory(at: versionsRoot),
              isSymbolicLink(at: currentLink),
              let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: currentLink) else {
            return []
        }
        let currentVersion = URL(fileURLWithPath: destination).lastPathComponent
        let currentPath = versionsRoot + "/" + currentVersion
        guard !currentVersion.isEmpty,
              isRealDirectory(at: currentPath),
              let currentModificationDate = directoryModificationDate(at: currentPath) else {
            return []
        }

        let directories = childDirectories(at: versionsRoot).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        var newestStagedPath: String?
        var newestModificationDate = currentModificationDate
        for directory in directories {
            guard let modificationDate = directoryModificationDate(at: directory),
                  modificationDate > newestModificationDate else {
                continue
            }
            newestModificationDate = modificationDate
            newestStagedPath = directory
        }
        return directories.filter { directory in
            !pathsEqual(directory, currentPath)
                && (newestStagedPath == nil || !pathsEqual(directory, newestStagedPath!))
                && !holdsCompiledModelCache(directory)
        }
    }

    private static func directoryModificationDate(at path: String) -> Date? {
        var value = stat()
        guard path.withCString({ lstat($0, &value) }) == 0,
              value.st_mode & S_IFMT == S_IFDIR else {
            return nil
        }
        return Date(
            timeIntervalSince1970: TimeInterval(value.st_mtimespec.tv_sec)
                + TimeInterval(value.st_mtimespec.tv_nsec) / 1_000_000_000
        )
    }

    private static func edgeUpdaterOldVersionItemIsAllowed(_ path: String) -> Bool {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard edgeIsInactive(),
              isRealDirectory(at: normalized),
              !isSymbolicLink(at: normalized),
              !holdsCompiledModelCache(normalized),
              pathsEqual(
                URL(fileURLWithPath: normalized).deletingLastPathComponent().path,
                edgeUpdaterVersionsRoot()
              ) else {
            return false
        }
        return edgeUpdaterOldVersionDirectories().contains {
            pathsEqual($0, normalized)
        }
    }

    private static func edgeUpdaterOldVersionDirectories() -> [String] {
        let directories = childDirectories(at: edgeUpdaterVersionsRoot()).sorted {
            versionName(at: $0).compare(
                versionName(at: $1),
                options: [.numeric, .caseInsensitive]
            ) == .orderedAscending
        }
        guard !directories.isEmpty else { return [] }
        if let installedVersion = installedEdgeVersion() {
            return directories.filter { directory in
                versionName(at: directory).compare(
                    installedVersion,
                    options: [.numeric, .caseInsensitive]
                ) == .orderedAscending
                    && !holdsCompiledModelCache(directory)
            }
        }
        guard directories.count >= 2, let newest = directories.last else { return [] }
        return directories.dropLast().filter {
            !pathsEqual($0, newest) && !holdsCompiledModelCache($0)
        }
    }

    private static func versionName(at path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    private static func installedEdgeVersion() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let appPaths = [
            "/Applications/Microsoft Edge.app",
            home + "/Applications/Microsoft Edge.app"
        ]
        for appPath in appPaths {
            let plistPath = appPath + "/Contents/Info.plist"
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: plistPath)),
                  let plist = try? PropertyListSerialization.propertyList(
                    from: data,
                    options: [],
                    format: nil
                  ),
                  let dictionary = plist as? [String: Any],
                  let version = dictionary["CFBundleShortVersionString"] as? String,
                  !version.isEmpty else {
                continue
            }
            return version
        }
        return nil
    }

    private static func edgeUpdaterVersionsRoot() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/Microsoft/EdgeUpdater/apps/msedge-stable",
                isDirectory: true
            )
            .standardizedFileURL.path
    }

    private static func chromeIsInactive() -> Bool {
        processProbesAreInactive([
            ["-x", "Google Chrome"],
            ["-x", "Google Chrome Helper"],
            ["-f", "/Google Chrome.app/"]
        ])
    }

    private static func firefoxIsInactive() -> Bool {
        processProbesAreInactive([["-x", "Firefox"]])
    }

    private static func braveIsInactive() -> Bool {
        processProbesAreInactive([["-x", "Brave Browser"]])
    }

    private static func arcIsInactive() -> Bool {
        processProbesAreInactive([["-x", "Arc"]])
    }

    private static func vivaldiIsInactive() -> Bool {
        processProbesAreInactive([["-x", "Vivaldi"]])
    }

    private static func qqBrowserIsInactive() -> Bool {
        processProbesAreInactive([["-x", "QQBrowser3"]])
    }

    private static func edgeIsInactive() -> Bool {
        processProbesAreInactive([["-x", "Microsoft Edge"]])
    }

    private static func processProbesAreInactive(_ probes: [[String]]) -> Bool {
        let executable = "/usr/bin/pgrep"
        guard !probes.isEmpty,
              FileManager.default.isExecutableFile(atPath: executable) else {
            return false
        }
        for arguments in probes {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
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
            guard process.terminationReason == .exit,
                  process.terminationStatus == 1 else {
                return false
            }
        }
        return true
    }

    private static func scanSharedContainerLogs() async -> (
        items: [CacheCleanupItem],
        unreadableItemCount: Int
    ) {
        let root = sharedContainerRoot()
        guard isRealDirectory(at: root) else { return ([], 0) }

        let containers: [URL]
        do {
            containers = try FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: root, isDirectory: true),
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isReadableKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            return ([], 1)
        }

        var items: [CacheCleanupItem] = []
        var unreadableItemCount = 0
        for container in containers {
            guard !Task.isCancelled else { return ([], 0) }
            let identifier = container.lastPathComponent
            guard sharedContainerIsAllowed(container.path, identifier: identifier) else { continue }

            for logRoot in sharedContainerLogRoots(container.path) where isRealDirectory(at: logRoot) {
                var finalUpdate: DiskAnalysisUpdate?
                for await update in DiskAnalyzer.updates(for: logRoot) {
                    guard !Task.isCancelled else { return ([], 0) }
                    if update.isComplete { finalUpdate = update }
                }
                guard let finalUpdate else {
                    unreadableItemCount += 1
                    continue
                }
                unreadableItemCount += finalUpdate.unreadableItemCount
                items.append(contentsOf: finalUpdate.entrySizes.compactMap { path, size in
                    guard sharedContainerLogItemIsAllowed(path),
                          !holdsCompiledModelCache(path),
                          ContainerCacheSafety.isConclusivelyIdle(at: path) else {
                        return nil
                    }
                    return CacheCleanupItem(
                        path: path,
                        category: .sharedContainerLogs,
                        sizeBytes: size
                    )
                })
            }
        }
        return (items, unreadableItemCount)
    }

    private static func sharedContainerLogItemIsAllowed(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard !isSymbolicLink(at: url.path) else { return false }

        let root = sharedContainerRoot()
        let parent = url.deletingLastPathComponent().path
        guard parent.hasPrefix(root + "/") else { return false }
        let relativeParent = parent
            .dropFirst(root.count + 1)
            .split(separator: "/")
            .map(String.init)
        let identifier: String
        let containerPath: String
        if relativeParent.count == 2, relativeParent[1] == "Logs" {
            identifier = relativeParent[0]
            containerPath = root + "/" + identifier
        } else if relativeParent.count == 3,
                  relativeParent[1] == "Library",
                  relativeParent[2] == "Logs" {
            identifier = relativeParent[0]
            containerPath = root + "/" + identifier
        } else {
            return false
        }
        return sharedContainerIsAllowed(containerPath, identifier: identifier)
            && sharedContainerLogRoots(containerPath).contains {
                pathsEqual($0, url.deletingLastPathComponent().path) && isRealDirectory(at: $0)
            }
    }

    private static func sharedContainerIsAllowed(_ path: String, identifier: String) -> Bool {
        let lowercased = identifier.lowercased()
        guard isRealDirectory(at: path),
              access(path, R_OK) == 0,
              !lowercased.hasPrefix("com.apple."),
              !lowercased.hasPrefix("group.com.apple."),
              !lowercased.hasPrefix("systemgroup.com.apple.") else {
            return false
        }
        return !isSafariExtensionContainer(identifier)
    }

    private static func isSafariExtensionContainer(_ identifier: String) -> Bool {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers", isDirectory: true)
            .appendingPathComponent(identifier, isDirectory: true)
            .standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return false
        }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: path,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            return true
        }
        return entries.contains {
            $0.lastPathComponent.localizedCaseInsensitiveContains("safari")
        }
    }

    private static func holdsCompiledModelCache(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        if url.lastPathComponent == "com.apple.e5rt.e5bundlecache" {
            return true
        }
        var isDirectory: ObjCBool = false
        let child = url.appendingPathComponent("com.apple.e5rt.e5bundlecache", isDirectory: true)
        return FileManager.default.fileExists(atPath: child.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private static func sharedContainerLogRoots(_ containerPath: String) -> [String] {
        [
            containerPath + "/Logs",
            containerPath + "/Library/Logs"
        ]
    }

    private static func sharedContainerRoot() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers", isDirectory: true)
            .standardizedFileURL.path
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

    private static func isRealFileOrDirectory(at path: String) -> Bool {
        var value = stat()
        guard path.withCString({ lstat($0, &value) }) == 0 else { return false }
        let kind = value.st_mode & S_IFMT
        return kind == S_IFDIR || kind == S_IFREG
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
