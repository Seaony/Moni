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
                sizeBytes: candidate.kind == .applicationBundle && application.steamAppID != nil
                    ? nil
                    : quickSize(at: normalized)
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
            for name in bundleLeafNameVariants(
                bundleIdentifier: bundleIdentifier,
                applicationName: application.name
            ) {
                add(home + "/Library/Application Support/" + name, .applicationSupport)
                add(home + "/Library/Caches/" + name, .cache)
                add(home + "/Library/Logs/" + name, .log)
                add(home + "/Library/Preferences/" + name + ".plist", .preference)
                add(home + "/Library/Saved Application State/" + name + ".savedState", .savedState)
            }

            let nested = vendorNestedCandidates(
                bundleIdentifier: bundleIdentifier,
                applicationName: application.name,
                roots: [
                    (home + "/Library/Application Support", .applicationSupport),
                    (home + "/Library/Caches", .cache),
                    (home + "/Library/Logs", .log)
                ]
            )
            candidates.append(contentsOf: nested.candidates)
            if !nested.isComplete { isComplete = false }
        }

        let pluginPaths: [(String, ApplicationRemovalKind)] = [
            (home + "/Library/Services/" + application.name + ".workflow", .other),
            (home + "/Library/QuickLook/" + application.name + ".qlgenerator", .other),
            (home + "/Library/Internet Plug-Ins/" + application.name + ".plugin", .other),
            (home + "/Library/Audio/Plug-Ins/Components/" + application.name + ".component", .other),
            (home + "/Library/Audio/Plug-Ins/VST/" + application.name + ".vst", .other),
            (home + "/Library/Audio/Plug-Ins/VST3/" + application.name + ".vst3", .other),
            (home + "/Library/Audio/Plug-Ins/Digidesign/" + application.name + ".dpm", .other),
            (home + "/Library/PreferencePanes/" + application.name + ".prefPane", .other),
            (home + "/Library/Input Methods/" + application.name + ".app", .other),
            (home + "/Library/Screen Savers/" + application.name + ".saver", .other),
            (home + "/Library/Frameworks/" + application.name + ".framework", .other),
            (home + "/Library/Contextual Menu Items/" + application.name + ".plugin", .other),
            (home + "/Library/Spotlight/" + application.name + ".mdimporter", .other),
            (home + "/Library/ColorPickers/" + application.name + ".colorPicker", .other),
            (home + "/Library/Workflows/" + application.name + ".workflow", .other),
            (home + "/Library/Address Book Plug-Ins/" + application.name + ".bundle", .other),
            (home + "/Library/Accessibility/" + application.name + ".bundle", .other),
            (home + "/Library/Mail/Bundles/" + application.name + ".mailbundle", .other)
        ]
        for (path, kind) in pluginPaths { add(path, kind) }

        let independentCLINames: Set<String> = ["claude", "opencode", "codex", "gemini"]
        if !independentCLINames.contains(application.name.lowercased()) {
            let xdgNames = Set(names.flatMap { [$0, $0.lowercased()] })
            for name in xdgNames {
                add(home + "/.config/" + name, .applicationSupport)
                add(home + "/.cache/" + name, .cache)
                add(home + "/.local/share/" + name, .applicationSupport)
            }
        }

        let developer = specializedDeveloperCandidates(for: application, home: home)
        candidates.append(contentsOf: developer.candidates)
        if !developer.isComplete { isComplete = false }
        candidates.append(contentsOf: specializedProductCandidates(for: application, home: home))

        let launchAgentRoot = home + "/Library/LaunchAgents"
        if application.name.count >= 5,
           !isCommonName(application.name),
           fileManager.fileExists(atPath: launchAgentRoot) {
            if let launchAgents = try? fileManager.contentsOfDirectory(
                at: URL(fileURLWithPath: launchAgentRoot, isDirectory: true),
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) {
                for launchAgent in launchAgents where
                    launchAgent.pathExtension.caseInsensitiveCompare("plist") == .orderedSame
                    && launchAgent.lastPathComponent.localizedCaseInsensitiveContains(application.name)
                    && !launchAgent.lastPathComponent.lowercased().hasPrefix("com.apple.") {
                    add(launchAgent.path, .launchAgent)
                }
            } else {
                isComplete = false
            }
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
                let allowedExtensions = ["ips", "crash", "spin", "diag"]
                guard allowedExtensions.contains(report.pathExtension.lowercased()) else { continue }
                if reportNames.contains(where: { name in
                    let helperName = name + " helper"
                    return lowercased.hasPrefix(name + ".")
                        || lowercased.hasPrefix(name + "_")
                        || lowercased.hasPrefix(name + "-")
                        || lowercased.hasPrefix(helperName + ".")
                        || lowercased.hasPrefix(helperName + "_")
                        || lowercased.hasPrefix(helperName + "-")
                }) {
                    add(report.path, .diagnosticReport)
                }
            }
        }

        let crashReporterRoot = home + "/Library/Application Support/CrashReporter"
        if fileManager.fileExists(atPath: crashReporterRoot) {
            if let crashReports = try? fileManager.contentsOfDirectory(
                at: URL(fileURLWithPath: crashReporterRoot, isDirectory: true),
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) {
                let prefixes = Set([application.name, application.name.replacingOccurrences(of: " ", with: "")])
                for report in crashReports where report.pathExtension.caseInsensitiveCompare("plist") == .orderedSame {
                    if prefixes.contains(where: { report.lastPathComponent.hasPrefix($0 + "_") }) {
                        add(report.path, .diagnosticReport)
                    }
                }
            } else {
                isComplete = false
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

    private static func bundleLeafNameVariants(
        bundleIdentifier: String,
        applicationName: String
    ) -> [String] {
        let leaf = bundleIdentifier.split(separator: ".").last.map(String.init) ?? ""
        let compactName = applicationName.replacingOccurrences(of: " ", with: "")
        guard leaf.count >= 8,
              compactName.count >= 3,
              leaf != applicationName,
              leaf.range(of: #"[a-z][A-Z]"#, options: .regularExpression) != nil,
              leaf.lowercased().hasPrefix(compactName.lowercased()) else {
            return []
        }
        let suffix = String(leaf.dropFirst(compactName.count))
        guard let first = suffix.first,
              first.isASCII,
              first.isUppercase || first.isNumber else {
            return []
        }
        let spacedSuffix = suffix
            .replacingOccurrences(
                of: #"([A-Z]+)([A-Z][a-z])"#,
                with: "$1 $2",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"([a-z0-9])([A-Z])"#,
                with: "$1 $2",
                options: .regularExpression
            )
        return Array(Set([leaf, applicationName + " " + spacedSuffix]))
            .filter { $0 != applicationName }
            .sorted()
    }

    private static func specializedDeveloperCandidates(
        for application: InstalledApplication,
        home: String
    ) -> (candidates: [Candidate], isComplete: Bool) {
        let name = application.name.lowercased()
        let bundleIdentifier = application.bundleIdentifier?.lowercased() ?? ""
        var candidates: [Candidate] = []
        var isComplete = true

        func add(_ path: String, _ kind: ApplicationRemovalKind) {
            if pathExists(path) { candidates.append(Candidate(path: path, kind: kind)) }
        }

        if name.contains("deveco")
            || bundleIdentifier.contains("huawei") && bundleIdentifier.contains("deveco") {
            add(home + "/Library/Caches/Huawei", .cache)
            add(home + "/Library/Logs/Huawei", .log)
        }

        if name.contains("android studio")
            || bundleIdentifier.contains("google") && bundleIdentifier.contains("android")
            || bundleIdentifier.contains("jetbrains") && bundleIdentifier.contains("android") {
            add(home + "/.android/cache", .cache)
            add(home + "/.android/build-cache", .cache)
            add(home + "/.android/breakpad", .cache)
            let googleRoot = home + "/Library/Application Support/Google"
            if pathExists(googleRoot) {
                if let children = try? FileManager.default.contentsOfDirectory(
                    at: URL(fileURLWithPath: googleRoot, isDirectory: true),
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                ) {
                    for child in children where
                        child.lastPathComponent.lowercased().hasPrefix("androidstudio") {
                        add(child.path, .applicationSupport)
                    }
                } else {
                    isComplete = false
                }
            }
        }

        if name.contains("xcode")
            || bundleIdentifier.contains("apple") && bundleIdentifier.contains("xcode") {
            let xcodePaths: [(String, ApplicationRemovalKind)] = [
                (home + "/Library/Developer/Xcode/DerivedData", .cache),
                (home + "/Library/Developer/Xcode/iOS DeviceSupport", .cache),
                (home + "/Library/Developer/Xcode/macOS DeviceSupport", .cache),
                (home + "/Library/Developer/Xcode/watchOS DeviceSupport", .cache),
                (home + "/Library/Developer/Xcode/tvOS DeviceSupport", .cache),
                (home + "/Library/Developer/Xcode/xrOS DeviceSupport", .cache),
                (home + "/Library/Developer/CoreSimulator/Caches", .cache),
                (home + "/.Xcode", .cache)
            ]
            for (path, kind) in xcodePaths { add(path, kind) }
        }

        let jetBrainsNames = [
            "intellij", "pycharm", "webstorm", "goland", "rubymine", "phpstorm",
            "clion", "datagrip", "rider"
        ]
        if bundleIdentifier.contains("jetbrains")
            || jetBrainsNames.contains(where: name.contains) {
            let roots: [(String, ApplicationRemovalKind)] = [
                (home + "/Library/Application Support/JetBrains", .applicationSupport),
                (home + "/Library/Caches/JetBrains", .cache),
                (home + "/Library/Logs/JetBrains", .log)
            ]
            for (rootPath, kind) in roots where pathExists(rootPath) {
                guard let children = try? FileManager.default.contentsOfDirectory(
                    at: URL(fileURLWithPath: rootPath, isDirectory: true),
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                ) else {
                    isComplete = false
                    continue
                }
                for child in children where
                    child.lastPathComponent.lowercased().hasPrefix(name) {
                    add(child.path, kind)
                }
            }
        }
        return (candidates, isComplete)
    }

    private static func specializedProductCandidates(
        for application: InstalledApplication,
        home: String
    ) -> [Candidate] {
        let name = application.name.lowercased()
        let bundleIdentifier = application.bundleIdentifier?.lowercased() ?? ""
        var candidates: [Candidate] = []

        func add(_ path: String, _ kind: ApplicationRemovalKind) {
            if pathExists(path) { candidates.append(Candidate(path: path, kind: kind)) }
        }

        if bundleIdentifier.contains("microsoft") && bundleIdentifier.contains("vscode") {
            add(home + "/Library/Caches/com.microsoft.VSCode.ShipIt", .cache)
            add(home + "/Library/Caches/com.microsoft.VSCodeInsiders.ShipIt", .cache)
            if bundleIdentifier.contains("insiders") {
                add(home + "/.vscode-insiders", .applicationSupport)
                add(home + "/Library/Application Support/Code - Insiders", .applicationSupport)
                add(home + "/Library/Caches/com.microsoft.VSCodeInsiders", .cache)
            } else {
                add(home + "/.vscode", .applicationSupport)
                add(home + "/Library/Application Support/Code", .applicationSupport)
                add(home + "/Library/Caches/com.microsoft.VSCode", .cache)
            }
        }

        if name.contains("docker") {
            add(home + "/.docker/buildx", .cache)
            add(home + "/.docker/scan", .cache)
        }
        if bundleIdentifier == "com.maestro.studio"
            || name.replacingOccurrences(of: " ", with: "").contains("maestrostudio") {
            add(home + "/.mobiledev", .applicationSupport)
        }
        if bundleIdentifier == "net.ankiweb.anki" || name == "anki" {
            add(home + "/Library/Application Support/AnkiProgramFiles", .applicationSupport)
        }
        if name.contains("unity") {
            add(home + "/Library/Unity", .applicationSupport)
        }
        if name.contains("unreal") {
            add(home + "/Library/Application Support/Epic", .applicationSupport)
        }
        if name.contains("godot") {
            add(home + "/Library/Application Support/Godot", .applicationSupport)
        }
        return candidates
    }

    private static func vendorNestedCandidates(
        bundleIdentifier: String,
        applicationName: String,
        roots: [(String, ApplicationRemovalKind)]
    ) -> (candidates: [Candidate], isComplete: Bool) {
        guard applicationName.count >= 4,
              !isCommonName(applicationName) else {
            return ([], true)
        }
        let parts = bundleIdentifier.split(separator: ".").map(String.init)
        guard parts.count >= 2 else { return ([], true) }
        let vendor = parts[parts.count - 2]
        let product = parts[parts.count - 1]
        guard isSafeBundleToken(vendor), isSafeBundleToken(product) else {
            return ([], true)
        }

        let variants = Set([
            applicationName,
            applicationName.replacingOccurrences(of: " ", with: ""),
            applicationName.replacingOccurrences(of: " ", with: "-"),
            applicationName.replacingOccurrences(of: " ", with: "_"),
            product
        ].map { $0.lowercased() })
        var candidates: [Candidate] = []
        var isComplete = true

        for (rootPath, kind) in roots where pathExists(rootPath) {
            let root = URL(fileURLWithPath: rootPath, isDirectory: true)
            guard let parents = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else {
                isComplete = false
                continue
            }
            for parent in parents where parent.lastPathComponent.caseInsensitiveCompare(vendor) == .orderedSame {
                guard let parentValues = try? parent.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                ), parentValues.isDirectory == true, parentValues.isSymbolicLink != true else {
                    continue
                }
                guard let children = try? FileManager.default.contentsOfDirectory(
                    at: parent,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                    options: [.skipsHiddenFiles]
                ) else {
                    isComplete = false
                    continue
                }
                for child in children {
                    guard let childValues = try? child.resourceValues(
                        forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                    ), childValues.isDirectory == true, childValues.isSymbolicLink != true else {
                        continue
                    }
                    let name = child.lastPathComponent.lowercased()
                    if variants.contains(where: { variant in
                        name == variant
                            || name.hasPrefix(variant + " ")
                            || name.hasPrefix(variant + "-")
                            || name.hasPrefix(variant + "_")
                            || name.hasPrefix(variant + ".")
                    }) {
                        candidates.append(Candidate(path: child.path, kind: kind))
                    }
                }
            }
        }
        return (candidates, isComplete)
    }

    private static func isSafeBundleToken(_ value: String) -> Bool {
        guard value.count >= 3, let first = value.unicodeScalars.first,
              CharacterSet.alphanumerics.contains(first), first.isASCII else {
            return false
        }
        return value.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-")
        }
    }

    private static func isCommonName(_ name: String) -> Bool {
        let common: Set<String> = [
            "app", "application", "music", "notes", "photos", "finder", "safari", "preview",
            "calendar", "contacts", "messages", "reminders", "clock", "weather", "stocks",
            "books", "news", "podcasts", "voice", "files", "store", "system", "helper",
            "agent", "daemon", "service", "update", "updater", "sync", "backup", "cloud",
            "manager", "monitor", "server", "client", "worker", "runner", "launcher", "driver",
            "plugin", "extension", "widget", "utility", "desktop", "support"
        ]
        return common.contains(name.lowercased())
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
