import Foundation

nonisolated enum ApplicationPostRemovalService {
    static func finish(
        application: InstalledApplication,
        allowBundleIdentifierMatch: Bool
    ) async {
        await Task.detached(priority: .utility) {
            removeDockEntries(
                applicationPath: application.path,
                bundleIdentifier: allowBundleIdentifierMatch ? application.bundleIdentifier : nil
            )
            refreshLaunchServices()
        }.value
    }

    private static func removeDockEntries(
        applicationPath: String,
        bundleIdentifier: String?
    ) {
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/com.apple.dock.plist")
            .path
        let plistBuddy = "/usr/libexec/PlistBuddy"
        guard FileManager.default.fileExists(atPath: plist),
              FileManager.default.isExecutableFile(atPath: plistBuddy) else { return }

        let path = URL(fileURLWithPath: applicationPath).standardizedFileURL.path
        let encodedPath = path.replacingOccurrences(of: " ", with: "%20")
        var changed = false
        for array in ["persistent-apps", "persistent-others", "recent-apps"] {
            var index = 0
            while let tileType = output(
                plistBuddy,
                arguments: ["-c", "Print :\(array):\(index):tile-type", plist]
            ), !tileType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let url = output(
                    plistBuddy,
                    arguments: ["-c", "Print :\(array):\(index):tile-data:file-data:_CFURLString", plist]
                ) ?? ""
                let dockBundleIdentifier = output(
                    plistBuddy,
                    arguments: ["-c", "Print :\(array):\(index):tile-data:bundle-identifier", plist]
                )?.trimmingCharacters(in: .whitespacesAndNewlines)
                let matchesBundle = bundleIdentifier != nil && dockBundleIdentifier == bundleIdentifier
                let matchesPath = url.contains(path) || url.contains(encodedPath)
                if matchesBundle || matchesPath {
                    if run(plistBuddy, arguments: ["-c", "Delete :\(array):\(index)", plist]) {
                        changed = true
                        continue
                    }
                }
                index += 1
            }
        }
        if changed {
            _ = run("/usr/bin/killall", arguments: ["Dock"])
        }
    }

    private static func refreshLaunchServices() {
        let executable = "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
        guard FileManager.default.isExecutableFile(atPath: executable) else { return }
        _ = run(executable, arguments: ["-gc"], timeout: 10)
        if !run(
            executable,
            arguments: ["-r", "-f", "-domain", "local", "-domain", "user", "-domain", "system"],
            timeout: 15
        ) {
            _ = run(
                executable,
                arguments: ["-r", "-f", "-domain", "local", "-domain", "user"],
                timeout: 10
            )
        }
    }

    private static func run(
        _ executable: String,
        arguments: [String],
        timeout: TimeInterval = 8
    ) -> Bool {
        command(executable, arguments: arguments, timeout: timeout)?.status == 0
    }

    private static func output(
        _ executable: String,
        arguments: [String],
        timeout: TimeInterval = 8
    ) -> String? {
        guard let result = command(executable, arguments: arguments, timeout: timeout),
              result.status == 0 else { return nil }
        return result.output
    }

    private static func command(
        _ executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) -> (status: Int32, output: String)? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let timeoutWork = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeoutWork.cancel()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
