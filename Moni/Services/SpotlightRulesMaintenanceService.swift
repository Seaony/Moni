import Foundation

nonisolated enum SpotlightRulesMaintenanceState: Sendable {
    case ready
    case protected
    case unavailable
    case incomplete
    case failed
}

nonisolated struct SpotlightRulesMaintenanceSnapshot: Sendable {
    let state: SpotlightRulesMaintenanceState
    let orphanedRules: [String]
}

nonisolated struct SpotlightRulesMaintenanceResult: Sendable {
    let removedCount: Int
    let skippedCount: Int
    let failedCount: Int
}

nonisolated enum SpotlightRulesMaintenanceService {
    private struct CommandOutput: Sendable {
        let status: Int32
        let output: Data
    }

    private struct InstalledBundleEvidence {
        var identifiers: Set<String> = []
        var helperIdentifiers: Set<String> = []
        var incomplete = false
    }

    private struct SearchRoot {
        let url: URL
        let maximumDepth: Int
    }

    private static let domain = "com.apple.spotlight"
    private static let rulesKey = "EnabledPreferenceRules"
    private static let defaultsExecutable = "/usr/bin/defaults"
    private static let metadataSearchExecutable = "/usr/bin/mdfind"

    static func scan() async -> SpotlightRulesMaintenanceSnapshot {
        await Task.detached(priority: .utility) {
            scanSynchronously()
        }.value
    }

    static func remove(_ plannedRules: [String]) async -> SpotlightRulesMaintenanceResult {
        await Task.detached(priority: .utility) {
            let current = scanSynchronously()
            guard current.state == .ready else {
                return SpotlightRulesMaintenanceResult(
                    removedCount: 0,
                    skippedCount: plannedRules.count,
                    failedCount: current.state == .failed ? 1 : 0
                )
            }

            let removable = Set(plannedRules).intersection(current.orphanedRules)
            guard !removable.isEmpty else {
                return SpotlightRulesMaintenanceResult(
                    removedCount: 0,
                    skippedCount: plannedRules.count,
                    failedCount: 0
                )
            }
            guard let currentRules = readRules() else {
                return SpotlightRulesMaintenanceResult(
                    removedCount: 0,
                    skippedCount: plannedRules.count,
                    failedCount: 1
                )
            }

            let keptRules = currentRules.filter { !removable.contains($0) }
            let succeeded: Bool
            if keptRules.isEmpty {
                succeeded = run(
                    defaultsExecutable,
                    arguments: ["delete", domain, rulesKey],
                    timeout: 8
                ).status == 0
            } else {
                succeeded = run(
                    defaultsExecutable,
                    arguments: ["write", domain, rulesKey, "-array"] + keptRules,
                    timeout: 8
                ).status == 0
            }
            return SpotlightRulesMaintenanceResult(
                removedCount: succeeded ? removable.count : 0,
                skippedCount: plannedRules.count - removable.count,
                failedCount: succeeded ? 0 : removable.count
            )
        }.value
    }

    private static func scanSynchronously() -> SpotlightRulesMaintenanceSnapshot {
        guard FileManager.default.isExecutableFile(atPath: defaultsExecutable) else {
            return SpotlightRulesMaintenanceSnapshot(state: .unavailable, orphanedRules: [])
        }
        let preferencePath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(domain).plist")
            .standardizedFileURL.path
        guard !CleanupPreferences.isWhitelisted(preferencePath) else {
            return SpotlightRulesMaintenanceSnapshot(state: .protected, orphanedRules: [])
        }
        guard let rules = readRules() else {
            return SpotlightRulesMaintenanceSnapshot(state: .failed, orphanedRules: [])
        }
        guard !rules.isEmpty else {
            return SpotlightRulesMaintenanceSnapshot(state: .ready, orphanedRules: [])
        }

        let candidates = rules.filter {
            !$0.hasPrefix("System.")
                && !$0.hasPrefix("com.apple.")
                && isReverseDNSBundleIdentifier($0)
        }
        guard !candidates.isEmpty else {
            return SpotlightRulesMaintenanceSnapshot(state: .ready, orphanedRules: [])
        }

        let evidence = installedBundleEvidence()
        guard !evidence.incomplete else {
            return SpotlightRulesMaintenanceSnapshot(state: .incomplete, orphanedRules: [])
        }
        let orphaned = candidates.filter { bundleIdentifier in
            !metadataSearchFinds(bundleIdentifier)
                && !evidenceContains(bundleIdentifier, evidence: evidence)
        }
        return SpotlightRulesMaintenanceSnapshot(
            state: .ready,
            orphanedRules: orphaned.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        )
    }

    private static func readRules() -> [String]? {
        let read = run(
            defaultsExecutable,
            arguments: ["read", domain, rulesKey],
            timeout: 8
        )
        if read.status != 0 { return [] }

        let exported = run(
            defaultsExecutable,
            arguments: ["export", domain, "-"],
            timeout: 8
        )
        guard exported.status == 0,
              let plist = try? PropertyListSerialization.propertyList(
                from: exported.output,
                options: [],
                format: nil
              ) as? [String: Any],
              let value = plist[rulesKey] else { return nil }
        return value as? [String]
    }

    private static func installedBundleEvidence() -> InstalledBundleEvidence {
        let fileManager = FileManager.default
        var evidence = InstalledBundleEvidence()
        for root in searchRoots() where fileManager.fileExists(atPath: root.url.path) {
            var rootReadFailed = false
            guard let enumerator = fileManager.enumerator(
                at: root.url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles],
                errorHandler: { _, _ in
                    rootReadFailed = true
                    return true
                }
            ) else {
                evidence.incomplete = true
                continue
            }

            let rootDepth = root.url.pathComponents.count
            while let url = enumerator.nextObject() as? URL {
                if Task.isCancelled {
                    evidence.incomplete = true
                    return evidence
                }
                let depth = url.pathComponents.count - rootDepth
                if depth > root.maximumDepth {
                    enumerator.skipDescendants()
                    continue
                }
                guard url.pathExtension.caseInsensitiveCompare("app") == .orderedSame else {
                    continue
                }
                enumerator.skipDescendants()
                let infoURL = url.appendingPathComponent("Contents/Info.plist")
                guard let data = try? Data(contentsOf: infoURL, options: .mappedIfSafe),
                      let plist = try? PropertyListSerialization.propertyList(
                        from: data,
                        options: [],
                        format: nil
                      ) as? [String: Any],
                      let identifier = plist["CFBundleIdentifier"] as? String,
                      !identifier.isEmpty else {
                    evidence.incomplete = true
                    continue
                }
                evidence.identifiers.insert(identifier.lowercased())
                collectHelperIdentifiers(at: url, evidence: &evidence)
            }
            if rootReadFailed { evidence.incomplete = true }
        }
        return evidence
    }

    private static func collectHelperIdentifiers(
        at applicationURL: URL,
        evidence: inout InstalledBundleEvidence
    ) {
        let directory = applicationURL.appendingPathComponent(
            "Contents/Library/LaunchServices",
            isDirectory: true
        )
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            evidence.incomplete = true
            return
        }
        evidence.helperIdentifiers.formUnion(files.map { $0.lastPathComponent.lowercased() })
    }

    private static func evidenceContains(
        _ bundleIdentifier: String,
        evidence: InstalledBundleEvidence
    ) -> Bool {
        let lowercased = bundleIdentifier.lowercased()
        if evidence.identifiers.contains(lowercased)
            || evidence.helperIdentifiers.contains(lowercased) {
            return true
        }
        for suffix in [".helper", ".daemon", ".agent", ".xpc", ".service"]
            where lowercased.hasSuffix(suffix) {
            if evidence.identifiers.contains(String(lowercased.dropLast(suffix.count))) {
                return true
            }
        }
        if ["com.microsoft.autoupdate.helper", "com.microsoft.office.licensingv2.helper"]
            .contains(lowercased) {
            let officeIdentifiers = [
                "com.microsoft.word", "com.microsoft.excel", "com.microsoft.powerpoint",
                "com.microsoft.outlook", "com.microsoft.onenote"
            ]
            return officeIdentifiers.contains { evidence.identifiers.contains($0) }
        }
        return false
    }

    private static func metadataSearchFinds(_ bundleIdentifier: String) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: metadataSearchExecutable) else {
            return false
        }
        let result = run(
            metadataSearchExecutable,
            arguments: ["kMDItemCFBundleIdentifier == '\(bundleIdentifier)'"],
            timeout: 5
        )
        return result.status == 0
            && !result.output.trimmingASCIIWhitespaceAndNewlines().isEmpty
    }

    private static func searchRoots() -> [SearchRoot] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            SearchRoot(url: URL(fileURLWithPath: "/Applications"), maximumDepth: 1),
            SearchRoot(url: URL(fileURLWithPath: "/Applications/Setapp"), maximumDepth: 3),
            SearchRoot(url: URL(fileURLWithPath: "/Applications/Utilities"), maximumDepth: 1),
            SearchRoot(url: URL(fileURLWithPath: "/System/Applications"), maximumDepth: 1),
            SearchRoot(url: URL(fileURLWithPath: "/System/Applications/Utilities"), maximumDepth: 1),
            SearchRoot(url: home.appendingPathComponent("Applications"), maximumDepth: 1),
            SearchRoot(
                url: home.appendingPathComponent("Library/Application Support/Setapp/Applications"),
                maximumDepth: 3
            ),
            SearchRoot(url: URL(fileURLWithPath: "/opt/homebrew/Caskroom"), maximumDepth: 3),
            SearchRoot(url: URL(fileURLWithPath: "/usr/local/Caskroom"), maximumDepth: 3),
            SearchRoot(url: URL(fileURLWithPath: "/Library/Input Methods"), maximumDepth: 1),
            SearchRoot(url: home.appendingPathComponent("Library/Input Methods"), maximumDepth: 1)
        ]
    }

    private static func isReverseDNSBundleIdentifier(_ value: String) -> Bool {
        value.range(
            of: #"^[A-Za-z0-9][-A-Za-z0-9]*(\.[A-Za-z0-9][-A-Za-z0-9]*)+$"#,
            options: .regularExpression
        ) != nil
    }

    private static func run(
        _ executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) -> CommandOutput {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        process.environment = environment
        do {
            try process.run()
        } catch {
            return CommandOutput(status: -1, output: Data())
        }
        let timeoutWork = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeoutWork.cancel()
        return CommandOutput(status: process.terminationStatus, output: output)
    }
}

private nonisolated extension Data {
    func trimmingASCIIWhitespaceAndNewlines() -> Data {
        let whitespace = Set([UInt8(9), UInt8(10), UInt8(13), UInt8(32)])
        guard let first = firstIndex(where: { !whitespace.contains($0) }),
              let last = lastIndex(where: { !whitespace.contains($0) }) else {
            return Data()
        }
        return self[first...last]
    }
}
