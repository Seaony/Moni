import Darwin
import Foundation

nonisolated struct ApplicationTeardownResult: Sendable {
    let failedActionCount: Int
}

nonisolated enum ApplicationTeardownService {
    static func perform(
        application: InstalledApplication,
        confirmedCandidates: [CleanupCandidate],
        inventory: ApplicationInventorySnapshot,
        hasSharedBundleIdentifier: Bool
    ) async -> ApplicationTeardownResult {
        await Task.detached(priority: .utility) {
            var failures = 0
            if matchesIdentity(application),
               application.path.lowercased().hasSuffix(".app") {
                let lsregister = "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
                _ = run(lsregister, arguments: ["-u", application.path])
            }
            guard !hasSharedBundleIdentifier else {
                return ApplicationTeardownResult(failedActionCount: 0)
            }
            for candidate in confirmedCandidates where isUserLaunchAgent(candidate.path) {
                guard matchesIdentity(candidate) else {
                    failures += 1
                    continue
                }
                if let label = launchdLabel(in: candidate.path) {
                    guard run("/bin/launchctl", arguments: ["print", "gui/\(getuid())/" + label]) else {
                        continue
                    }
                    if !run("/bin/launchctl", arguments: ["unload", candidate.path]) {
                        failures += 1
                    }
                } else {
                    _ = run("/bin/launchctl", arguments: ["unload", candidate.path])
                }
            }

            let userDomain = "gui/\(getuid())"
            for identifier in loginItemHelperIdentifiers(in: application.path) {
                guard run("/bin/launchctl", arguments: ["print", userDomain + "/" + identifier]) else {
                    continue
                }
                if !run("/bin/launchctl", arguments: ["bootout", userDomain + "/" + identifier]) {
                    failures += 1
                }
            }

            let hasSameNameApplication = inventory.applications.contains { candidate in
                candidate.path != application.path
                    && candidate.name.caseInsensitiveCompare(application.name) == .orderedSame
                    && FileManager.default.fileExists(atPath: candidate.path)
            }
            if !hasSameNameApplication,
               !removeLegacyLoginItem(named: application.name) {
                failures += 1
            }
            return ApplicationTeardownResult(failedActionCount: failures)
        }.value
    }

    private static func isUserLaunchAgent(_ path: String) -> Bool {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .standardizedFileURL.path + "/"
        let url = URL(fileURLWithPath: path).standardizedFileURL
        return url.path.hasPrefix(root)
            && url.deletingLastPathComponent().path + "/" == root
            && url.pathExtension.caseInsensitiveCompare("plist") == .orderedSame
    }

    private static func loginItemHelperIdentifiers(in applicationPath: String) -> [String] {
        let root = URL(fileURLWithPath: applicationPath, isDirectory: true)
            .appendingPathComponent("Contents/Library/LoginItems", isDirectory: true)
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return Array(Set(children.compactMap { url -> String? in
            guard url.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
                  let identifier = Bundle(url: url)?.bundleIdentifier,
                  isValidBundleIdentifier(identifier),
                  !identifier.lowercased().hasPrefix("com.apple.") else { return nil }
            return identifier
        })).sorted()
    }

    private static func launchdLabel(in plistPath: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: plistPath)),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let values = plist as? [String: Any],
              let label = values["Label"] as? String,
              isValidBundleIdentifier(label),
              !label.lowercased().hasPrefix("com.apple.") else { return nil }
        return label
    }

    private static func removeLegacyLoginItem(named applicationName: String) -> Bool {
        let name = URL(fileURLWithPath: applicationName).deletingPathExtension().lastPathComponent
        guard !name.isEmpty else { return true }
        let script = """
        on run argv
            set targetName to item 1 of argv
            tell application "System Events"
                set itemCount to count of login items
                repeat with itemIndex from itemCount to 1 by -1
                    try
                        if name of login item itemIndex is targetName then
                            delete login item itemIndex
                        end if
                    end try
                end repeat
            end tell
        end run
        """
        return run("/usr/bin/osascript", arguments: ["-e", script, name])
    }

    private static func run(_ executable: String, arguments: [String]) -> Bool {
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
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 8, execute: timeout)
        process.waitUntilExit()
        timeout.cancel()
        return process.terminationStatus == 0
    }

    private static func matchesIdentity(_ candidate: CleanupCandidate) -> Bool {
        var value = stat()
        guard candidate.path.withCString({ lstat($0, &value) }) == 0 else { return false }
        return UInt64(value.st_dev) == candidate.device && UInt64(value.st_ino) == candidate.inode
    }

    private static func matchesIdentity(_ application: InstalledApplication) -> Bool {
        var value = stat()
        guard application.path.withCString({ lstat($0, &value) }) == 0 else { return false }
        return UInt64(value.st_dev) == application.device && UInt64(value.st_ino) == application.inode
    }

    private static func isValidBundleIdentifier(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return parts.allSatisfy { part in
            !part.isEmpty && part.unicodeScalars.allSatisfy(allowed.contains)
        }
    }
}
