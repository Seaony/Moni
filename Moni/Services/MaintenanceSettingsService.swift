import Foundation

nonisolated struct LegacySystemOverride: Identifiable, Sendable {
    let domain: String
    let key: String
    let titleKey: String
    let preferencePath: String

    var id: String { domain + "|" + key }
}

nonisolated struct MaintenanceSettingsSnapshot: Sendable {
    let dsStoreKeysToEnable: [String]
    let legacyOverrides: [LegacySystemOverride]
    let launchServicesAvailable: Bool
}

nonisolated struct MaintenanceCommandResult: Sendable {
    let changedCount: Int
    let failedCount: Int
    let unavailable: Bool
}

nonisolated enum MaintenanceSettingsService {
    private static let defaultsExecutable = "/usr/bin/defaults"
    private static let dsStoreDomain = "com.apple.desktopservices"
    private static let dsStoreKeys = ["DSDontWriteNetworkStores", "DSDontWriteUSBStores"]

    static func scan() async -> MaintenanceSettingsSnapshot {
        await Task.detached(priority: .utility) {
            let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
            let missingDSStoreKeys = dsStoreKeys.filter {
                !isTruthy(readDefaults(domain: dsStoreDomain, key: $0))
            }

            let candidates = [
                LegacySystemOverride(
                    domain: "-g",
                    key: "NSAppSleepDisabled",
                    titleKey: "App Nap disabled globally",
                    preferencePath: home + "/Library/Preferences/.GlobalPreferences.plist"
                ),
                LegacySystemOverride(
                    domain: "com.apple.frameworks.diskimages",
                    key: "skip-verify",
                    titleKey: "Disk image verification disabled",
                    preferencePath: home + "/Library/Preferences/com.apple.frameworks.diskimages.plist"
                ),
                LegacySystemOverride(
                    domain: "com.apple.frameworks.diskimages",
                    key: "skip-verify-locked",
                    titleKey: "Locked disk image verification disabled",
                    preferencePath: home + "/Library/Preferences/com.apple.frameworks.diskimages.plist"
                ),
                LegacySystemOverride(
                    domain: "com.apple.frameworks.diskimages",
                    key: "skip-verify-remote",
                    titleKey: "Remote disk image verification disabled",
                    preferencePath: home + "/Library/Preferences/com.apple.frameworks.diskimages.plist"
                )
            ]
            let overrides = candidates.filter {
                isTruthy(readDefaults(domain: $0.domain, key: $0.key))
                    && !CleanupPreferences.isWhitelisted($0.preferencePath)
            }

            return MaintenanceSettingsSnapshot(
                dsStoreKeysToEnable: missingDSStoreKeys,
                legacyOverrides: overrides,
                launchServicesAvailable: launchServicesExecutable() != nil
            )
        }.value
    }

    static func enableDSStorePrevention() async -> MaintenanceCommandResult {
        await Task.detached(priority: .utility) {
            let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
            let preferencePath = home + "/Library/Preferences/" + dsStoreDomain + ".plist"
            if FileManager.default.fileExists(atPath: preferencePath),
               CleanupPreferences.isWhitelisted(preferencePath) {
                return MaintenanceCommandResult(changedCount: 0, failedCount: 0, unavailable: false)
            }

            var changedCount = 0
            var failedCount = 0
            for key in dsStoreKeys {
                if isTruthy(readDefaults(domain: dsStoreDomain, key: key)) { continue }
                if run(defaultsExecutable, arguments: ["write", dsStoreDomain, key, "-bool", "true"]) {
                    changedCount += 1
                } else {
                    failedCount += 1
                }
            }
            return MaintenanceCommandResult(
                changedCount: changedCount,
                failedCount: failedCount,
                unavailable: false
            )
        }.value
    }

    static func removeLegacyOverrides(_ overrides: [LegacySystemOverride]) async -> MaintenanceCommandResult {
        await Task.detached(priority: .utility) {
            var changedCount = 0
            var failedCount = 0
            for override in overrides {
                guard !CleanupPreferences.isWhitelisted(override.preferencePath),
                      isTruthy(readDefaults(domain: override.domain, key: override.key)) else { continue }
                if run(defaultsExecutable, arguments: ["delete", override.domain, override.key]) {
                    changedCount += 1
                } else {
                    failedCount += 1
                }
            }
            return MaintenanceCommandResult(
                changedCount: changedCount,
                failedCount: failedCount,
                unavailable: false
            )
        }.value
    }

    static func rebuildLaunchServices() async -> MaintenanceCommandResult {
        await Task.detached(priority: .utility) {
            guard let executable = launchServicesExecutable() else {
                return MaintenanceCommandResult(changedCount: 0, failedCount: 0, unavailable: true)
            }
            _ = run(executable, arguments: ["-gc"], timeout: 10)
            let rebuiltAllDomains = run(
                executable,
                arguments: ["-r", "-f", "-domain", "local", "-domain", "user", "-domain", "system"],
                timeout: 20
            )
            let rebuiltUserDomains = rebuiltAllDomains || run(
                executable,
                arguments: ["-r", "-f", "-domain", "local", "-domain", "user"],
                timeout: 15
            )
            return MaintenanceCommandResult(
                changedCount: rebuiltUserDomains ? 1 : 0,
                failedCount: rebuiltUserDomains ? 0 : 1,
                unavailable: false
            )
        }.value
    }

    private static func launchServicesExecutable() -> String? {
        let candidates = [
            "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
            "/System/Library/CoreServices/Frameworks/LaunchServices.framework/Support/lsregister"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func readDefaults(domain: String, key: String) -> String? {
        let result = runWithOutput(defaultsExecutable, arguments: ["read", domain, key])
        guard result.succeeded else { return nil }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isTruthy(_ value: String?) -> Bool {
        guard let value = value?.lowercased() else { return false }
        return ["1", "true", "yes"].contains(value)
    }

    private static func run(
        _ executable: String,
        arguments: [String],
        timeout: TimeInterval = 8
    ) -> Bool {
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
        let timeoutWork = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
        process.waitUntilExit()
        timeoutWork.cancel()
        return process.terminationStatus == 0
    }

    private static func runWithOutput(
        _ executable: String,
        arguments: [String]
    ) -> (succeeded: Bool, output: String) {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (false, "")
        }
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus == 0, String(decoding: data, as: UTF8.self))
    }
}
