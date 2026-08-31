import Darwin
import Foundation

nonisolated enum ApplicationInstallSource: String, Sendable {
    case systemApplications
    case userApplications
    case systemInputMethods
    case userInputMethods
    case externalVolume
}

nonisolated struct InstalledApplication: Identifiable, Sendable {
    let path: String
    let canonicalPath: String
    let name: String
    let bundleIdentifier: String?
    let version: String?
    let executableName: String?
    let sizeBytes: UInt64?
    let lastUsedDate: Date?
    let modifiedDate: Date?
    let source: ApplicationInstallSource
    let device: UInt64
    let inode: UInt64

    var id: String { path }
}

nonisolated struct ApplicationInventorySnapshot: Sendable {
    let applications: [InstalledApplication]
    let unreadablePaths: [String]

    var isComplete: Bool { unreadablePaths.isEmpty }
}

nonisolated enum ApplicationInventoryService {
    private struct SearchRoot: Sendable {
        let path: String
        let source: ApplicationInstallSource
    }

    private struct BundleMetadata {
        let name: String
        let bundleIdentifier: String?
        let version: String?
        let executableName: String?
        let isBackgroundOnly: Bool
    }

    static func scan() async -> ApplicationInventorySnapshot {
        await Task.detached(priority: .utility) {
            scanSynchronously()
        }.value
    }

    private static func scanSynchronously() -> ApplicationInventorySnapshot {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser.standardizedFileURL.path
        var roots = [
            SearchRoot(path: "/Applications", source: .systemApplications),
            SearchRoot(path: home + "/Applications", source: .userApplications),
            SearchRoot(path: "/Library/Input Methods", source: .systemInputMethods),
            SearchRoot(path: home + "/Library/Input Methods", source: .userInputMethods)
        ]
        roots.append(contentsOf: externalApplicationRoots(fileManager: fileManager))

        var applications: [InstalledApplication] = []
        var unreadablePaths: [String] = []
        var seenCanonicalPaths: Set<String> = []

        for root in roots {
            guard !Task.isCancelled,
                  fileManager.fileExists(atPath: root.path) else {
                continue
            }
            guard let enumerator = fileManager.enumerator(
                at: URL(fileURLWithPath: root.path, isDirectory: true),
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles],
                errorHandler: { url, _ in
                    unreadablePaths.append(url.path)
                    return true
                }
            ) else {
                unreadablePaths.append(root.path)
                continue
            }

            let rootDepth = URL(fileURLWithPath: root.path).pathComponents.count
            while let url = enumerator.nextObject() as? URL {
                guard !Task.isCancelled else {
                    return ApplicationInventorySnapshot(applications: [], unreadablePaths: [])
                }
                let depth = url.pathComponents.count - rootDepth
                if depth > 3 {
                    enumerator.skipDescendants()
                    continue
                }
                guard url.pathExtension.caseInsensitiveCompare("app") == .orderedSame else {
                    continue
                }
                enumerator.skipDescendants()

                let canonicalPath = url.resolvingSymlinksInPath().standardizedFileURL.path
                guard !isSystemTarget(canonicalPath),
                      seenCanonicalPaths.insert(canonicalPath).inserted else {
                    continue
                }
                guard let identity = fileIdentity(at: url) else {
                    unreadablePaths.append(url.path)
                    continue
                }

                switch readMetadata(at: url) {
                case let .success(metadata):
                    if metadata.isBackgroundOnly,
                       url.deletingLastPathComponent().standardizedFileURL.path != root.path {
                        continue
                    }
                    let spotlight = spotlightMetadata(at: url)
                    let modifiedDate = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                        .contentModificationDate
                    applications.append(InstalledApplication(
                        path: url.standardizedFileURL.path,
                        canonicalPath: canonicalPath,
                        name: metadata.name,
                        bundleIdentifier: metadata.bundleIdentifier,
                        version: metadata.version,
                        executableName: metadata.executableName,
                        sizeBytes: spotlight.sizeBytes,
                        lastUsedDate: spotlight.lastUsedDate,
                        modifiedDate: modifiedDate ?? nil,
                        source: root.source,
                        device: identity.device,
                        inode: identity.inode
                    ))
                case .failure:
                    unreadablePaths.append(url.path)
                }
            }
        }

        return ApplicationInventorySnapshot(
            applications: deduplicated(applications),
            unreadablePaths: Array(Set(unreadablePaths)).sorted()
        )
    }

    private static func externalApplicationRoots(fileManager: FileManager) -> [SearchRoot] {
        let volumesRoot = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        guard let volumes = try? fileManager.contentsOfDirectory(
            at: volumesRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return volumes.compactMap { volume in
            let applications = volume.appendingPathComponent("Applications", isDirectory: true)
            guard fileManager.fileExists(atPath: applications.path) else { return nil }
            return SearchRoot(path: applications.standardizedFileURL.path, source: .externalVolume)
        }
    }

    private static func readMetadata(at appURL: URL) -> Result<BundleMetadata, Error> {
        let fallbackName = appURL.deletingPathExtension().lastPathComponent
        guard let infoURL = infoPlistURL(for: appURL) else {
            return .success(BundleMetadata(
                name: fallbackName,
                bundleIdentifier: nil,
                version: nil,
                executableName: nil,
                isBackgroundOnly: false
            ))
        }

        do {
            let data = try Data(contentsOf: infoURL, options: .mappedIfSafe)
            guard let dictionary = try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ) as? [String: Any] else {
                throw CocoaError(.propertyListReadCorrupt)
            }
            let metadataName = stringValue(dictionary["CFBundleDisplayName"])
                ?? stringValue(dictionary["CFBundleName"])
            let name = resolvedDisplayName(metadataName, fallbackName: fallbackName)
            return .success(BundleMetadata(
                name: name,
                bundleIdentifier: stringValue(dictionary["CFBundleIdentifier"]),
                version: stringValue(dictionary["CFBundleShortVersionString"]),
                executableName: stringValue(dictionary["CFBundleExecutable"]),
                isBackgroundOnly: boolValue(dictionary["LSBackgroundOnly"])
            ))
        } catch {
            return .failure(error)
        }
    }

    private static func infoPlistURL(for appURL: URL) -> URL? {
        let fileManager = FileManager.default
        let standard = appURL.appendingPathComponent("Contents/Info.plist")
        if fileManager.fileExists(atPath: standard.path) {
            return standard
        }
        let wrapper = appURL.appendingPathComponent("Wrapper", isDirectory: true)
        guard let wrappedApps = try? fileManager.contentsOfDirectory(
            at: wrapper,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        return wrappedApps
            .filter { $0.pathExtension.caseInsensitiveCompare("app") == .orderedSame }
            .map { $0.appendingPathComponent("Info.plist") }
            .first { fileManager.fileExists(atPath: $0.path) }
    }

    private static func spotlightMetadata(at url: URL) -> (sizeBytes: UInt64?, lastUsedDate: Date?) {
        guard let item = NSMetadataItem(url: url) else { return (nil, nil) }
        let size = (item.value(forAttribute: "kMDItemPhysicalSize") as? NSNumber)?.uint64Value
        let lastUsed = item.value(forAttribute: "kMDItemLastUsedDate") as? Date
        return (size.flatMap { $0 > 0 ? $0 : nil }, lastUsed)
    }

    private static func resolvedDisplayName(_ metadataName: String?, fallbackName: String) -> String {
        guard let metadataName, !metadataName.isEmpty else { return fallbackName }
        if fallbackName.hasPrefix(metadataName), fallbackName != metadataName,
           fallbackName.dropFirst(metadataName.count).contains(where: \.isNumber) {
            return fallbackName
        }
        return metadataName
    }

    private static func stringValue(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let sanitized = value
            .replacingOccurrences(of: "|", with: "-")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        return sanitized.isEmpty ? nil : sanitized
    }

    private static func boolValue(_ value: Any?) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String {
            return ["1", "yes", "true"].contains(value.lowercased())
        }
        return false
    }

    private static func fileIdentity(at url: URL) -> (device: UInt64, inode: UInt64)? {
        var value = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &value)
        }
        guard result == 0 else { return nil }
        return (UInt64(value.st_dev), UInt64(value.st_ino))
    }

    private static func isSystemTarget(_ path: String) -> Bool {
        let normalized = path.lowercased()
        return normalized == "/system" || normalized.hasPrefix("/system/")
            || normalized == "/usr" || normalized.hasPrefix("/usr/")
            || normalized == "/bin" || normalized.hasPrefix("/bin/")
            || normalized == "/sbin" || normalized.hasPrefix("/sbin/")
            || normalized == "/private/etc" || normalized.hasPrefix("/private/etc/")
    }

    private static func deduplicated(_ applications: [InstalledApplication]) -> [InstalledApplication] {
        var byKey: [String: InstalledApplication] = [:]
        var pathOnly: [InstalledApplication] = []
        for application in applications {
            guard let bundleIdentifier = application.bundleIdentifier?.lowercased() else {
                pathOnly.append(application)
                continue
            }
            let key = bundleIdentifier + "|" + URL(fileURLWithPath: application.path).lastPathComponent.lowercased()
            if let existing = byKey[key] {
                if pathRank(application) < pathRank(existing) {
                    byKey[key] = application
                }
            } else {
                byKey[key] = application
            }
        }
        return (Array(byKey.values) + pathOnly).sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private static func pathRank(_ application: InstalledApplication) -> Int {
        switch application.source {
        case .systemApplications: 1
        case .userApplications: 2
        case .systemInputMethods, .userInputMethods: 3
        case .externalVolume: 4
        }
    }
}
