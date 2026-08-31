import Darwin
import Foundation

nonisolated enum HomebrewMaintenanceState: Sendable {
    case ready
    case healthy
    case protected
    case unavailable
    case failed
}

nonisolated struct HomebrewMaintenanceSnapshot: Sendable {
    let cachePath: String
    let cacheSizeBytes: UInt64
    let autoremoveFormulae: [String]
    let state: HomebrewMaintenanceState
}

nonisolated enum HomebrewCleanupOutcome: Sendable {
    case cleaned(reclaimedBytes: UInt64, restoredLinkCount: Int, autoremoveFormulae: [String])
    case noAction
    case protected
    case unavailable
    case failed
}

nonisolated enum HomebrewMaintenanceService {
    private struct BrewPaths: Sendable {
        let prefix: String
        let cellar: String
    }

    private struct ActiveLink: Sendable {
        let path: String
        let target: String
        let resolvedTarget: String
    }

    private struct CommandResult: Sendable {
        let output: String
        let succeeded: Bool
    }

    private static let cleanupThresholdBytes: UInt64 = 50 * 1_024 * 1_024
    private static let cleanupTimeout: TimeInterval = 120

    static func scan() async -> HomebrewMaintenanceSnapshot {
        let cachePath = homebrewCachePath()
        guard let executable = brewExecutable() else {
            return HomebrewMaintenanceSnapshot(
                cachePath: cachePath,
                cacheSizeBytes: 0,
                autoremoveFormulae: [],
                state: .unavailable
            )
        }
        guard !CleanupPreferences.isWhitelisted(cachePath) else {
            return HomebrewMaintenanceSnapshot(
                cachePath: cachePath,
                cacheSizeBytes: 0,
                autoremoveFormulae: [],
                state: .protected
            )
        }

        var cacheSizeBytes: UInt64 = 0
        if FileManager.default.fileExists(atPath: cachePath) {
            guard isRealDirectory(at: cachePath) else {
                return HomebrewMaintenanceSnapshot(
                    cachePath: cachePath,
                    cacheSizeBytes: 0,
                    autoremoveFormulae: [],
                    state: .failed
                )
            }
            var finalUpdate: DiskAnalysisUpdate?
            for await update in DiskAnalyzer.updates(for: cachePath) {
                guard !Task.isCancelled else {
                    return HomebrewMaintenanceSnapshot(
                        cachePath: cachePath,
                        cacheSizeBytes: 0,
                        autoremoveFormulae: [],
                        state: .failed
                    )
                }
                if update.isComplete { finalUpdate = update }
            }
            guard let finalUpdate, finalUpdate.unreadableItemCount == 0 else {
                return HomebrewMaintenanceSnapshot(
                    cachePath: cachePath,
                    cacheSizeBytes: 0,
                    autoremoveFormulae: [],
                    state: .failed
                )
            }
            cacheSizeBytes = finalUpdate.scannedBytes
        }

        let preview = await Task.detached(priority: .utility) {
            runBrew(executable, arguments: ["autoremove", "--dry-run"], timeout: 15)
        }.value
        let formulae = preview.succeeded ? parseAutoremoveFormulae(preview.output) : []
        return HomebrewMaintenanceSnapshot(
            cachePath: cachePath,
            cacheSizeBytes: cacheSizeBytes,
            autoremoveFormulae: formulae,
            state: cacheSizeBytes >= cleanupThresholdBytes ? .ready : .healthy
        )
    }

    static func clean() async -> HomebrewCleanupOutcome {
        let before = await scan()
        switch before.state {
        case .healthy:
            return .noAction
        case .protected:
            return .protected
        case .unavailable:
            return .unavailable
        case .failed:
            return .failed
        case .ready:
            break
        }
        guard let executable = brewExecutable() else { return .unavailable }
        guard !CleanupPreferences.isWhitelisted(before.cachePath) else { return .protected }
        guard let paths = brewPaths(using: executable) else { return .failed }

        let links = activeLinks(in: paths)
        let cleanup = await Task.detached(priority: .utility) {
            runBrew(executable, arguments: ["cleanup", "--prune=30"], timeout: cleanupTimeout)
        }.value
        let restoredLinkCount = restoreActiveLinks(links, expected: paths, executable: executable)
        guard cleanup.succeeded else { return .failed }

        let after = await scan()
        guard after.state != .unavailable, after.state != .failed else { return .failed }
        return .cleaned(
            reclaimedBytes: before.cacheSizeBytes > after.cacheSizeBytes
                ? before.cacheSizeBytes - after.cacheSizeBytes
                : 0,
            restoredLinkCount: restoredLinkCount,
            autoremoveFormulae: after.autoremoveFormulae
        )
    }

    private static func activeLinks(in paths: BrewPaths) -> [ActiveLink] {
        var links: [ActiveLink] = []
        for directory in [paths.prefix + "/bin", paths.prefix + "/sbin"] {
            guard isRealDirectory(at: directory),
                  let entries = try? FileManager.default.contentsOfDirectory(
                    at: URL(fileURLWithPath: directory, isDirectory: true),
                    includingPropertiesForKeys: [.isSymbolicLinkKey],
                    options: []
                  ) else {
                continue
            }
            for entry in entries {
                let linkPath = entry.standardizedFileURL.path
                guard isSymbolicLink(at: linkPath),
                      let target = try? FileManager.default.destinationOfSymbolicLink(atPath: linkPath),
                      let resolvedTarget = resolvedCellarTarget(
                        target,
                        linkPath: linkPath,
                        paths: paths
                      ) else {
                    continue
                }
                links.append(ActiveLink(path: linkPath, target: target, resolvedTarget: resolvedTarget))
            }
        }
        return links
    }

    private static func restoreActiveLinks(
        _ links: [ActiveLink],
        expected: BrewPaths,
        executable: String
    ) -> Int {
        guard let current = brewPaths(using: executable),
              pathsEqual(current.prefix, expected.prefix),
              pathsEqual(current.cellar, expected.cellar) else {
            return 0
        }
        var restored = 0
        for link in links {
            let linkURL = URL(fileURLWithPath: link.path).standardizedFileURL
            let parent = linkURL.deletingLastPathComponent().path
            guard [current.prefix + "/bin", current.prefix + "/sbin"].contains(where: {
                pathsEqual(parent, $0)
            }),
            !pathExists(link.path),
            isRealDirectory(at: parent),
            pathsEqual(
                URL(fileURLWithPath: parent, isDirectory: true)
                    .resolvingSymlinksInPath().standardizedFileURL.path,
                parent
            ),
            FileManager.default.fileExists(atPath: link.resolvedTarget),
            pathIsInside(link.resolvedTarget, root: current.cellar),
            resolvedCellarTarget(
                link.target,
                linkPath: link.path,
                paths: current
            ).map({ pathsEqual($0, link.resolvedTarget) }) == true else {
                continue
            }
            do {
                try FileManager.default.createSymbolicLink(
                    atPath: link.path,
                    withDestinationPath: link.target
                )
                restored += 1
            } catch {
                continue
            }
        }
        return restored
    }

    private static func resolvedCellarTarget(
        _ target: String,
        linkPath: String,
        paths: BrewPaths
    ) -> String? {
        let candidate: String
        if target.hasPrefix("/") {
            candidate = target
        } else if target.hasPrefix("../Cellar/"), pathsEqual(paths.cellar, paths.prefix + "/Cellar") {
            candidate = paths.cellar + "/" + String(target.dropFirst("../Cellar/".count))
        } else {
            return nil
        }
        guard !candidate.contains("//"),
              !candidate.split(separator: "/", omittingEmptySubsequences: false).contains("..") else {
            return nil
        }
        let resolved = URL(fileURLWithPath: candidate)
            .resolvingSymlinksInPath().standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: resolved),
              pathIsInside(resolved, root: paths.cellar),
              (pathsEqual(
                URL(fileURLWithPath: linkPath).deletingLastPathComponent().path,
                paths.prefix + "/bin"
              ) || pathsEqual(
                URL(fileURLWithPath: linkPath).deletingLastPathComponent().path,
                paths.prefix + "/sbin"
              )) else {
            return nil
        }
        return resolved
    }

    private static func brewPaths(using executable: String) -> BrewPaths? {
        let prefixResult = runBrew(executable, arguments: ["--prefix"], timeout: 10)
        let cellarResult = runBrew(executable, arguments: ["--cellar"], timeout: 10)
        guard prefixResult.succeeded,
              cellarResult.succeeded,
              let prefix = safeDirectoryOutput(prefixResult.output),
              let cellar = safeDirectoryOutput(cellarResult.output) else {
            return nil
        }
        return BrewPaths(prefix: prefix, cellar: cellar)
    }

    private static func safeDirectoryOutput(_ output: String) -> String? {
        let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix("/"),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !value.contains("//"),
              !value.split(separator: "/", omittingEmptySubsequences: false).contains("."),
              !value.split(separator: "/", omittingEmptySubsequences: false).contains("..") else {
            return nil
        }
        let physical = URL(fileURLWithPath: value, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL.path
        return isRealDirectory(at: physical) ? physical : nil
    }

    private static func parseAutoremoveFormulae(_ output: String) -> [String] {
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        guard let header = lines.firstIndex(where: {
            $0.range(
                of: "^(==> )?Would autoremove [0-9]+ unneeded formula",
                options: .regularExpression
            ) != nil
        }) else {
            return []
        }
        return lines.dropFirst(header + 1).compactMap { line in
            let value = line.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty, !value.hasPrefix("==>") else { return nil }
            return value
        }
    }

    private static func runBrew(
        _ executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) -> CommandResult {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["HOMEBREW_NO_ENV_HINTS"] = "1"
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        environment["HOMEBREW_NO_AUTOREMOVE"] = "1"
        environment["HOMEBREW_NO_COLOR"] = "1"
        environment["NONINTERACTIVE"] = "1"
        process.environment = environment
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
        } catch {
            return CommandResult(output: "", succeeded: false)
        }
        let timeoutWork = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeoutWork.cancel()
        return CommandResult(
            output: String(data: data, encoding: .utf8) ?? "",
            succeeded: process.terminationReason == .exit && process.terminationStatus == 0
        )
    }

    private static func brewExecutable() -> String? {
        var candidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        if let environmentPath = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: environmentPath.split(separator: ":").map {
                URL(fileURLWithPath: String($0), isDirectory: true)
                    .appendingPathComponent("brew")
                    .standardizedFileURL.path
            })
        }
        var seen = Set<String>()
        return candidates.first { candidate in
            let standardized = URL(fileURLWithPath: candidate).standardizedFileURL.path
            guard seen.insert(standardized).inserted else { return false }
            return FileManager.default.isExecutableFile(atPath: standardized)
        }
    }

    private static func homebrewCachePath() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/Homebrew", isDirectory: true)
            .standardizedFileURL.path
    }

    private static func isRealDirectory(at path: String) -> Bool {
        var value = stat()
        return path.withCString { lstat($0, &value) } == 0
            && value.st_mode & S_IFMT == S_IFDIR
    }

    private static func isSymbolicLink(at path: String) -> Bool {
        var value = stat()
        return path.withCString { lstat($0, &value) } == 0
            && value.st_mode & S_IFMT == S_IFLNK
    }

    private static func pathExists(_ path: String) -> Bool {
        var value = stat()
        return path.withCString { lstat($0, &value) } == 0
    }

    private static func pathIsInside(_ path: String, root: String) -> Bool {
        path.lowercased().hasPrefix(root.lowercased() + "/")
    }

    private static func pathsEqual(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: [.caseInsensitive, .literal]) == .orderedSame
    }
}
