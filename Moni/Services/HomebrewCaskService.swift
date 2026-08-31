import Darwin
import Foundation

nonisolated enum HomebrewCaskOwnership: Sendable, Equatable {
    case notManaged
    case managed(String)
    case unavailable
}

nonisolated enum HomebrewCaskUninstallResult: Sendable {
    case removed
    case caskRemovedApplicationRemains
    case stillInstalled
    case applicationChanged
    case unavailable
}

nonisolated enum HomebrewCaskService {
    static func ownership(of application: InstalledApplication) async -> HomebrewCaskOwnership {
        await Task.detached(priority: .utility) {
            detectOwnership(of: application)
        }.value
    }

    static func uninstall(
        token: String,
        application: InstalledApplication,
        useZap: Bool
    ) async -> HomebrewCaskUninstallResult {
        await Task.detached(priority: .userInitiated) {
            guard isValidCaskToken(token),
                  let brew = brewExecutable() else { return .unavailable }
            guard matchesIdentity(application) else { return .applicationChanged }

            var arguments = ["uninstall", "--cask"]
            if useZap { arguments.append("--zap") }
            arguments.append(token)
            let timeout: TimeInterval
            switch application.sizeBytes ?? 0 {
            case (15 * 1_024 * 1_024 * 1_024)...:
                timeout = 900
            case (5 * 1_024 * 1_024 * 1_024)...:
                timeout = 600
            default:
                timeout = 300
            }
            _ = runBrew(brew, arguments: arguments, timeout: timeout)

            switch installedCasks(using: brew) {
            case .failure:
                return .unavailable
            case let .success(installed) where installed.contains(token):
                return .stillInstalled
            case .success:
                return FileManager.default.fileExists(atPath: application.path)
                    ? .caskRemovedApplicationRemains
                    : .removed
            }
        }.value
    }

    private static func detectOwnership(of application: InstalledApplication) -> HomebrewCaskOwnership {
        let appURL = URL(fileURLWithPath: application.path).standardizedFileURL
        let resolvedPath = appURL.resolvingSymlinksInPath().path
        if URL(fileURLWithPath: resolvedPath).lastPathComponent == appURL.lastPathComponent,
           let token = caskToken(from: resolvedPath) {
            return .managed(token)
        }

        guard let brew = brewExecutable() else { return .notManaged }

        switch caskroomMatches(for: appURL.lastPathComponent) {
        case .failure:
            return .unavailable
        case let .success(tokens) where tokens.count == 1:
            let token = tokens[0]
            switch installedCasks(using: brew) {
            case .failure:
                return .unavailable
            case let .success(installed):
                guard installed.contains(token) else { break }
                return verifiedOwnership(
                    token: token,
                    applicationURL: appURL,
                    brew: brew
                )
            }
        case .success:
            break
        }

        switch installedCasks(using: brew) {
        case .failure:
            return .unavailable
        case let .success(installed):
            let appName = appURL.deletingPathExtension().lastPathComponent.lowercased()
            guard installed.contains(appName) else { return .notManaged }
            return verifiedOwnership(
                token: appName,
                applicationURL: appURL,
                brew: brew
            )
        }
    }

    private static func verifiedOwnership(
        token: String,
        applicationURL: URL,
        brew: String
    ) -> HomebrewCaskOwnership {
        guard let output = runBrew(brew, arguments: ["info", "--cask", token]) else {
            return .unavailable
        }
        if output.contains(applicationURL.path) {
            return .managed(token)
        }
        if applicationURL.deletingLastPathComponent().path == "/Applications",
           output.contains(applicationURL.lastPathComponent) {
            return .managed(token)
        }
        return .notManaged
    }

    private static func caskroomMatches(for bundleName: String) -> Result<[String], Error> {
        var matches: Set<String> = []
        for root in ["/opt/homebrew/Caskroom", "/usr/local/Caskroom"] {
            guard FileManager.default.fileExists(atPath: root) else { continue }
            var failed = false
            guard let enumerator = FileManager.default.enumerator(
                at: URL(fileURLWithPath: root, isDirectory: true),
                includingPropertiesForKeys: nil,
                options: [],
                errorHandler: { _, _ in
                    failed = true
                    return false
                }
            ) else {
                return .failure(CaskProbeError.unreadableCaskroom)
            }
            let rootDepth = URL(fileURLWithPath: root).pathComponents.count
            while let url = enumerator.nextObject() as? URL {
                let depth = url.pathComponents.count - rootDepth
                if depth > 3 {
                    enumerator.skipDescendants()
                    continue
                }
                guard url.lastPathComponent == bundleName,
                      let token = caskToken(from: url.path) else { continue }
                matches.insert(token)
            }
            if failed { return .failure(CaskProbeError.unreadableCaskroom) }
        }
        return .success(matches.sorted())
    }

    private static func installedCasks(using brew: String) -> Result<Set<String>, Error> {
        guard let output = runBrew(brew, arguments: ["list", "--cask"]) else {
            return .failure(CaskProbeError.commandFailed)
        }
        let tokens = output.split(whereSeparator: \.isNewline).map(String.init)
        return .success(Set(tokens))
    }

    private static func runBrew(
        _ executable: String,
        arguments: [String],
        timeout timeoutInterval: TimeInterval = 8
    ) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        environment["HOMEBREW_NO_ENV_HINTS"] = "1"
        environment["NONINTERACTIVE"] = "1"
        process.environment = environment
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }
        let timeout = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeoutInterval, execute: timeout)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func brewExecutable() -> String? {
        var candidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { String($0) + "/brew" })
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func caskToken(from path: String) -> String? {
        for prefix in ["/opt/homebrew/Caskroom/", "/usr/local/Caskroom/"] where path.hasPrefix(prefix) {
            guard let token = path.dropFirst(prefix.count).split(separator: "/").first,
                  token.range(of: "^[a-z0-9][a-z0-9-]*$", options: .regularExpression) != nil else {
                return nil
            }
            return String(token)
        }
        return nil
    }

    private static func isValidCaskToken(_ token: String) -> Bool {
        token.range(of: "^[a-z0-9][a-z0-9-]*$", options: .regularExpression) != nil
    }

    private static func matchesIdentity(_ application: InstalledApplication) -> Bool {
        var value = stat()
        guard application.path.withCString({ lstat($0, &value) }) == 0 else { return false }
        return UInt64(value.st_dev) == application.device && UInt64(value.st_ino) == application.inode
    }

    private enum CaskProbeError: Error {
        case unreadableCaskroom
        case commandFailed
    }
}
