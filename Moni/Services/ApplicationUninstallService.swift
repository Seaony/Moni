import Darwin
import Foundation

nonisolated enum ApplicationRemovalKind: String, Sendable {
    case applicationBundle
    case applicationSupport
    case cache
    case log
    case preference
    case container
    case webData
    case launchAgent
    case savedState
    case diagnosticReport
    case other
}

nonisolated struct ApplicationRemovalItem: Identifiable, Sendable {
    let path: String
    let kind: ApplicationRemovalKind
    let sizeBytes: UInt64?

    var id: String { path }
}

nonisolated enum ApplicationUninstallWarning: String, Sendable {
    case incompleteApplicationInventory
    case sharedBundleIdentifier
    case incompleteResidualScan
}

nonisolated struct ApplicationUninstallPreview: Sendable {
    let application: InstalledApplication
    let items: [ApplicationRemovalItem]
    let reviewOnlySystemItems: [ApplicationRemovalItem]
    let warnings: [ApplicationUninstallWarning]
    let homebrewCask: String?
    let homebrewProbeUnavailable: Bool

    var estimatedSizeBytes: UInt64 {
        items.reduce(UInt64(0)) { total, item in
            let (sum, overflow) = total.addingReportingOverflow(item.sizeBytes ?? 0)
            return overflow ? UInt64.max : sum
        }
    }
}

nonisolated enum ApplicationUninstallService {
    private struct Candidate {
        let path: String
        let kind: ApplicationRemovalKind
    }

    static func preview(
        application: InstalledApplication,
        inventory: ApplicationInventorySnapshot
    ) async -> ApplicationUninstallPreview {
        var warnings: [ApplicationUninstallWarning] = []
        var candidates = [Candidate(path: application.path, kind: .applicationBundle)]
        var reviewOnlySystemCandidates: [Candidate] = []
        let caskOwnership = await HomebrewCaskService.ownership(of: application)

        if !inventory.isComplete {
            warnings.append(.incompleteApplicationInventory)
        }

        let hasSibling = hasSurvivingSibling(for: application, in: inventory.applications)
        if hasSibling {
            warnings.append(.sharedBundleIdentifier)
        } else if inventory.isComplete {
            let result = residualCandidates(for: application)
            candidates.append(contentsOf: result.candidates)
            reviewOnlySystemCandidates = systemReviewCandidates(for: application)
            if !result.isComplete {
                warnings.append(.incompleteResidualScan)
            }
        }

        candidates = collapsed(candidates)
        let eligible = await CleanupService.shared.eligiblePaths(candidates.map(\.path))
        let items = candidates.compactMap { candidate -> ApplicationRemovalItem? in
            let normalized = URL(fileURLWithPath: candidate.path).standardizedFileURL.path
            guard eligible.contains(normalized) else { return nil }
            return ApplicationRemovalItem(
                path: normalized,
                kind: candidate.kind,
                sizeBytes: quickSize(at: normalized)
            )
        }
        let reviewOnlySystemItems = collapsed(reviewOnlySystemCandidates).map { candidate in
            ApplicationRemovalItem(
                path: candidate.path,
                kind: candidate.kind,
                sizeBytes: quickSize(at: candidate.path)
            )
        }

        return ApplicationUninstallPreview(
            application: application,
            items: items,
            reviewOnlySystemItems: reviewOnlySystemItems,
            warnings: warnings,
            homebrewCask: {
                if case let .managed(token) = caskOwnership { return token }
                return nil
            }(),
            homebrewProbeUnavailable: caskOwnership == .unavailable
        )
    }

    static func officialUninstallerVendor(for application: InstalledApplication) -> String? {
        let bundleIdentifier = application.bundleIdentifier?.lowercased() ?? ""
        let name = application.name.lowercased()
        let pathName = URL(fileURLWithPath: application.path).deletingPathExtension().lastPathComponent.lowercased()
        let rules: [(vendor: String, bundlePrefixes: [String], nameFragments: [String])] = [
            ("ESET", ["com.eset."], ["eset management agent", "eset remote administrator agent", "eset endpoint security", "eset endpoint antivirus"]),
            ("Jamf", ["com.jamf.", "com.jamfsoftware."], ["jamf connect", "jamf protect", "jamf self service"]),
            ("CrowdStrike", ["com.crowdstrike."], ["crowdstrike", "falcon"]),
            ("SentinelOne", ["com.sentinelone.", "com.sentinel-labs."], ["sentinelone", "sentinel agent"]),
            ("GlobalProtect", ["com.paloaltonetworks."], ["globalprotect"]),
            ("Cisco", ["com.cisco.anyconnect", "com.cisco.secureclient"], ["cisco secure client", "cisco anyconnect"])
        ]
        return rules.first { rule in
            rule.bundlePrefixes.contains { bundleIdentifier.hasPrefix($0) }
                || rule.nameFragments.contains { name.contains($0) || pathName.contains($0) }
        }?.vendor
    }

    private static func residualCandidates(
        for application: InstalledApplication
    ) -> (candidates: [Candidate], isComplete: Bool) {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser.standardizedFileURL.path
        var candidates: [Candidate] = []
        var isComplete = true

        func add(_ path: String, _ kind: ApplicationRemovalKind) {
            if pathExists(path) {
                candidates.append(Candidate(path: path, kind: kind))
            }
        }

        let names = safeNameVariants(application.name)
        for name in names {
            add(home + "/Library/Application Support/" + name, .applicationSupport)
            add(home + "/Library/Caches/" + name, .cache)
            add(home + "/Library/Logs/" + name, .log)
            add(home + "/Library/Preferences/" + name, .preference)
            add(home + "/Library/Preferences/" + name + ".plist", .preference)
            add(home + "/Library/Saved Application State/" + name + ".savedState", .savedState)
        }

        if let bundleIdentifier = application.bundleIdentifier,
           isValidBundleIdentifier(bundleIdentifier) {
            let exactPaths: [(String, ApplicationRemovalKind)] = [
                (home + "/Library/Application Support/" + bundleIdentifier, .applicationSupport),
                (home + "/Library/Caches/" + bundleIdentifier, .cache),
                (home + "/Library/Logs/" + bundleIdentifier, .log),
                (home + "/Library/Preferences/" + bundleIdentifier, .preference),
                (home + "/Library/Preferences/" + bundleIdentifier + ".plist", .preference),
                (home + "/Library/Saved Application State/" + bundleIdentifier + ".savedState", .savedState),
                (home + "/Library/Containers/" + bundleIdentifier, .container),
                (home + "/Library/WebKit/" + bundleIdentifier, .webData),
                (home + "/Library/WebKit/com.apple.WebKit.WebContent/" + bundleIdentifier, .webData),
                (home + "/Library/HTTPStorages/" + bundleIdentifier, .webData),
                (home + "/Library/HTTPStorages/" + bundleIdentifier + ".binarycookies", .webData),
                (home + "/Library/Cookies/" + bundleIdentifier + ".binarycookies", .webData),
                (home + "/Library/Application Scripts/" + bundleIdentifier, .container),
                (home + "/Library/Input Methods/" + bundleIdentifier + ".app", .other),
                (home + "/Library/Autosave Information/" + bundleIdentifier, .other),
                (home + "/Library/SyncedPreferences/" + bundleIdentifier + ".plist", .preference),
                (home + "/Library/Caches/com.apple.nsurlsessiond/Downloads/" + bundleIdentifier, .cache)
            ]
            for (path, kind) in exactPaths {
                add(path, kind)
            }

            let scannedRoots: [(String, ApplicationRemovalKind)] = [
                (home + "/Library/Preferences/ByHost", .preference),
                (home + "/Library/LaunchAgents", .launchAgent),
                (home + "/Library/Group Containers", .container),
                (home + "/Library/Application Scripts", .container),
                (home + "/Library/Containers", .container),
                (home + "/Library/Application Support/FileProvider", .applicationSupport)
            ]
            for (root, kind) in scannedRoots {
                guard fileManager.fileExists(atPath: root) else { continue }
                guard let children = try? fileManager.contentsOfDirectory(
                    at: URL(fileURLWithPath: root, isDirectory: true),
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                ) else {
                    isComplete = false
                    continue
                }
                for child in children where hasBundleIdentifierBoundary(
                    child.deletingPathExtension().lastPathComponent,
                    bundleIdentifier: bundleIdentifier
                ) {
                    add(child.path, kind)
                }
            }

            let recentDocuments = home
                + "/Library/Application Support/com.apple.sharedfilelist/"
                + "com.apple.LSSharedFileList.ApplicationRecentDocuments"
            for suffix in ["sfl2", "sfl3", "sfl4"] {
                add(recentDocuments + "/" + bundleIdentifier + "." + suffix, .other)
            }

            let embeddedResult = embeddedBundleIdentifiers(
                in: application.path,
                primaryBundleIdentifier: bundleIdentifier
            )
            if !embeddedResult.isComplete {
                isComplete = false
            }
            for embeddedIdentifier in embeddedResult.identifiers {
                let embeddedPaths: [(String, ApplicationRemovalKind)] = [
                    (home + "/Library/Application Scripts/" + embeddedIdentifier, .container),
                    (home + "/Library/Application Support/FileProvider/" + embeddedIdentifier, .applicationSupport),
                    (home + "/Library/Caches/" + embeddedIdentifier, .cache),
                    (home + "/Library/Containers/" + embeddedIdentifier, .container),
                    (home + "/Library/HTTPStorages/" + embeddedIdentifier, .webData),
                    (home + "/Library/HTTPStorages/" + embeddedIdentifier + ".binarycookies", .webData),
                    (home + "/Library/Preferences/" + embeddedIdentifier + ".plist", .preference),
                    (home + "/Library/WebKit/" + embeddedIdentifier, .webData)
                ]
                for (path, kind) in embeddedPaths {
                    add(path, kind)
                }

                let byHostRoot = home + "/Library/Preferences/ByHost"
                guard fileManager.fileExists(atPath: byHostRoot) else { continue }
                guard let children = try? fileManager.contentsOfDirectory(
                    at: URL(fileURLWithPath: byHostRoot, isDirectory: true),
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                ) else {
                    isComplete = false
                    continue
                }
                for child in children where hasBundleIdentifierBoundary(
                    child.deletingPathExtension().lastPathComponent,
                    bundleIdentifier: embeddedIdentifier
                ) {
                    add(child.path, .preference)
                }
            }
        }

        let reportRoots = [
            home + "/Library/Logs/DiagnosticReports",
            home + "/Library/DiagnosticReports"
        ]
        let reportNames = Set(
            ([application.executableName, application.name].compactMap { $0 })
                .filter { !$0.isEmpty }
                .map { $0.lowercased() }
        )
        for root in reportRoots {
            guard fileManager.fileExists(atPath: root) else { continue }
            guard let reports = try? fileManager.contentsOfDirectory(
                at: URL(fileURLWithPath: root, isDirectory: true),
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                isComplete = false
                continue
            }
            for report in reports {
                let lowercased = report.lastPathComponent.lowercased()
                if reportNames.contains(where: {
                    lowercased == $0 || lowercased.hasPrefix($0 + "_") || lowercased.hasPrefix($0 + "-")
                }) {
                    add(report.path, .diagnosticReport)
                }
            }
        }

        return (candidates, isComplete)
    }

    private static func systemReviewCandidates(for application: InstalledApplication) -> [Candidate] {
        var candidates: [Candidate] = []
        func add(_ path: String, _ kind: ApplicationRemovalKind = .other) {
            if pathExists(path) { candidates.append(Candidate(path: path, kind: kind)) }
        }

        for name in safeNameVariants(application.name) {
            add("/Library/Application Support/" + name, .applicationSupport)
            add("/Library/Caches/" + name, .cache)
            add("/Library/Logs/" + name, .log)
            add("/Library/Preferences/" + name, .preference)
            add("/Library/Preferences/" + name + ".plist", .preference)
            add("/Users/Shared/" + name)
        }

        add("/Library/Frameworks/" + application.name + ".framework")
        add("/Library/Internet Plug-Ins/" + application.name + ".plugin")
        add("/Library/Input Methods/" + application.name + ".app")
        add("/Library/Audio/Plug-Ins/Components/" + application.name + ".component")
        add("/Library/Audio/Plug-Ins/VST/" + application.name + ".vst")
        add("/Library/Audio/Plug-Ins/VST3/" + application.name + ".vst3")
        add("/Library/Audio/Plug-Ins/Digidesign/" + application.name + ".dpm")
        add("/Library/QuickLook/" + application.name + ".qlgenerator")
        add("/Library/PreferencePanes/" + application.name + ".prefPane")
        add("/Library/Screen Savers/" + application.name + ".saver")
        add("/Library/Extensions/" + application.name + ".kext")
        add("/Library/StartupItems/" + application.name)

        guard let bundleIdentifier = application.bundleIdentifier,
              isValidBundleIdentifier(bundleIdentifier) else { return collapsed(candidates) }

        let exactPaths: [(String, ApplicationRemovalKind)] = [
            ("/Library/Application Support/" + bundleIdentifier, .applicationSupport),
            ("/Library/Caches/" + bundleIdentifier, .cache),
            ("/Library/Logs/" + bundleIdentifier, .log),
            ("/Library/Preferences/" + bundleIdentifier + ".plist", .preference),
            ("/Library/LaunchAgents/" + bundleIdentifier + ".plist", .launchAgent),
            ("/Library/LaunchDaemons/" + bundleIdentifier + ".plist", .launchAgent),
            ("/Library/Receipts/" + bundleIdentifier + ".bom", .other),
            ("/Library/Receipts/" + bundleIdentifier + ".plist", .other)
        ]
        for (path, kind) in exactPaths { add(path, kind) }

        let scannedRoots: [(String, ApplicationRemovalKind)] = [
            ("/Library/LaunchAgents", .launchAgent),
            ("/Library/LaunchDaemons", .launchAgent),
            ("/Library/PrivilegedHelperTools", .other),
            ("/private/var/db/receipts", .other)
        ]
        for (root, kind) in scannedRoots {
            guard let children = try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: root, isDirectory: true),
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for child in children where hasBundleIdentifierBoundary(
                child.deletingPathExtension().lastPathComponent,
                bundleIdentifier: bundleIdentifier
            ) {
                if !child.lastPathComponent.lowercased().hasPrefix("com.apple.") {
                    add(child.path, kind)
                }
            }
        }
        return collapsed(candidates)
    }

    private static func embeddedBundleIdentifiers(
        in applicationPath: String,
        primaryBundleIdentifier: String
    ) -> (identifiers: [String], isComplete: Bool) {
        let fileManager = FileManager.default
        let contentsURL = URL(fileURLWithPath: applicationPath, isDirectory: true)
            .appendingPathComponent("Contents", isDirectory: true)
        guard fileManager.fileExists(atPath: contentsURL.path) else { return ([], true) }

        var isComplete = true
        guard let enumerator = fileManager.enumerator(
            at: contentsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [],
            errorHandler: { _, _ in
                isComplete = false
                return true
            }
        ) else {
            return ([], false)
        }

        var identifiers: Set<String> = []
        var scannedInfoPlists = 0
        while let url = enumerator.nextObject() as? URL {
            if enumerator.level > 12 {
                enumerator.skipDescendants()
                continue
            }
            guard url.lastPathComponent == "Info.plist",
                  url.deletingLastPathComponent().lastPathComponent == "Contents" else {
                continue
            }

            scannedInfoPlists += 1
            guard scannedInfoPlists <= 128 else { break }
            let bundleRoot = url.deletingLastPathComponent().deletingLastPathComponent()
            guard bundleRoot.standardizedFileURL.path
                != URL(fileURLWithPath: applicationPath).standardizedFileURL.path else { continue }

            let extensionName = bundleRoot.pathExtension.lowercased()
            if extensionName == "app" {
                let loginItemsRoot = contentsURL
                    .appendingPathComponent("Library/LoginItems", isDirectory: true)
                    .standardizedFileURL.path + "/"
                guard bundleRoot.standardizedFileURL.path.hasPrefix(loginItemsRoot) else { continue }
            } else if extensionName != "xpc" && extensionName != "appex" {
                continue
            }

            guard let data = try? Data(contentsOf: url),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
                  let values = plist as? [String: Any],
                  let identifier = values["CFBundleIdentifier"] as? String,
                  isValidBundleIdentifier(identifier),
                  identifier != primaryBundleIdentifier,
                  !identifier.lowercased().hasPrefix("org.sparkle-project.") else {
                continue
            }
            identifiers.insert(identifier)
        }

        return (identifiers.sorted(), isComplete)
    }

    private static func safeNameVariants(_ name: String) -> [String] {
        guard name.count >= 4 else { return [] }
        let forbidden = ["local", "config", "cache", "support", "system", "helper", "agent", "service"]
        guard !forbidden.contains(name.lowercased()) else { return [] }

        var names = [name]
        if name.contains(" ") {
            names.append(name.replacingOccurrences(of: " ", with: ""))
            names.append(name.replacingOccurrences(of: " ", with: "_"))
            names.append(name.replacingOccurrences(of: " ", with: "-"))
        }
        let suffixes = [
            " Nightly", " Beta", " Alpha", " Dev", " Canary", " Preview", " Insider",
            " Edge", " Stable", " Release", " RC", " LTS", " Developer Edition",
            " Technology Preview"
        ]
        if let suffix = suffixes.first(where: { name.hasSuffix($0) }) {
            let base = String(name.dropLast(suffix.count))
            if base.count >= 3 { names.append(base) }
        }
        return Array(Set(names)).sorted()
    }

    private static func isValidBundleIdentifier(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return parts.allSatisfy { part in
            !part.isEmpty && part.unicodeScalars.allSatisfy(allowed.contains)
        }
    }

    private static func hasBundleIdentifierBoundary(_ name: String, bundleIdentifier: String) -> Bool {
        let name = name.lowercased()
        let bundle = bundleIdentifier.lowercased()
        return name == bundle || name.hasPrefix(bundle + ".") || name.hasSuffix("." + bundle)
            || name.contains("." + bundle + ".")
    }

    private static func hasSurvivingSibling(
        for application: InstalledApplication,
        in applications: [InstalledApplication]
    ) -> Bool {
        guard let bundleIdentifier = application.bundleIdentifier?.lowercased() else { return false }
        return applications.contains { candidate in
            candidate.path != application.path
                && candidate.bundleIdentifier?.lowercased() == bundleIdentifier
                && FileManager.default.fileExists(atPath: candidate.path)
        }
    }

    private static func collapsed(_ candidates: [Candidate]) -> [Candidate] {
        var seen: Set<String> = []
        let unique = candidates.compactMap { candidate -> Candidate? in
            let path = URL(fileURLWithPath: candidate.path).standardizedFileURL.path
            guard seen.insert(path.lowercased()).inserted else { return nil }
            return Candidate(path: path, kind: candidate.kind)
        }
        return unique.sorted { pathDepth($0.path) < pathDepth($1.path) }.reduce(into: []) { result, candidate in
            guard !result.contains(where: { pathContains($0.path, candidate.path) }) else { return }
            result.append(candidate)
        }
    }

    private static func pathDepth(_ path: String) -> Int {
        path.split(separator: "/").count
    }

    private static func pathContains(_ parent: String, _ child: String) -> Bool {
        let parent = parent.lowercased()
        let child = child.lowercased()
        return child == parent || child.hasPrefix(parent + "/")
    }

    private static func quickSize(at path: String) -> UInt64? {
        guard let item = NSMetadataItem(url: URL(fileURLWithPath: path)),
              let value = item.value(forAttribute: "kMDItemPhysicalSize") as? NSNumber,
              value.uint64Value > 0 else {
            return nil
        }
        return value.uint64Value
    }

    private static func pathExists(_ path: String) -> Bool {
        var value = stat()
        return path.withCString { lstat($0, &value) } == 0
    }
}
