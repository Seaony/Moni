import Darwin
import Foundation

nonisolated struct UserCacheProcessGuard: Sendable {
    private let processLines: [String]
    private let runningBundleIdentifiers: Set<String>

    static func capture() -> UserCacheProcessGuard? {
        guard let processOutput = run(
            "/bin/ps",
            arguments: ["-axo", "pid=,comm=,args="],
            timeout: 5
        ), !processOutput.isEmpty else {
            return nil
        }

        let ownPID = String(getpid())
        let processLines = processOutput
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { line in
                line.trimmingCharacters(in: .whitespaces)
                    .split(separator: " ")
                    .first
                    .map(String.init) != ownPID
            }
        guard !processLines.isEmpty else { return nil }

        let applicationOutput = run(
            "/usr/bin/lsappinfo",
            arguments: ["list"],
            timeout: 5
        ) ?? ""
        let bundleIdentifiers = Set(applicationOutput
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> String? in
                let marker = "bundleID=\""
                guard let start = line.range(of: marker)?.upperBound,
                      let end = line[start...].firstIndex(of: "\"") else {
                    return nil
                }
                return String(line[start..<end]).lowercased()
            })

        return UserCacheProcessGuard(
            processLines: processLines,
            runningBundleIdentifiers: bundleIdentifiers
        )
    }

    static func permits(_ path: String, using snapshot: UserCacheProcessGuard?) -> Bool {
        guard let owner = cacheOwner(for: path) else { return true }
        guard let snapshot else { return false }
        return !snapshot.ownerIsRunning(owner)
    }

    static func permits(owner: String, using snapshot: UserCacheProcessGuard?) -> Bool {
        guard owner.contains("."),
              !owner.hasPrefix("."),
              let snapshot else {
            return false
        }
        return !snapshot.ownerIsRunning(owner)
    }

    private func ownerIsRunning(_ owner: String) -> Bool {
        let lowercasedOwner = owner.lowercased()
        if runningBundleIdentifiers.contains(lowercasedOwner) {
            return true
        }
        if processLines.contains(where: {
            $0.range(of: owner, options: [.caseInsensitive, .literal]) != nil
        }) {
            return true
        }

        let components = owner.split(separator: ".").map(String.init)
        guard let leaf = components.last,
              leaf.count >= 4 else {
            return false
        }
        let corroborators = components.dropLast().filter {
            $0.count >= 4 && $0.caseInsensitiveCompare("com") != .orderedSame
        }
        guard !corroborators.isEmpty else { return false }

        return processLines.contains { line in
            containsDelimitedToken(leaf, in: line)
                && corroborators.contains { containsDelimitedToken($0, in: line) }
        }
    }

    private static func cacheOwner(for rawPath: String) -> String? {
        let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches", isDirectory: true)
            .standardizedFileURL.path
        guard path.hasPrefix(root + "/") else { return nil }
        let component = path.dropFirst(root.count + 1).split(separator: "/").first.map(String.init)
        guard let component,
              component.contains("."),
              !component.hasPrefix(".") else {
            return nil
        }
        return component
    }

    private func containsDelimitedToken(_ token: String, in line: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: token)
        return line.range(
            of: "(^|[^A-Za-z0-9])\(escaped)([^A-Za-z0-9]|$)",
            options: [.caseInsensitive, .regularExpression]
        ) != nil
    }

    private static func run(
        _ executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) -> String? {
        guard FileManager.default.isExecutableFile(atPath: executable) else { return nil }
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        process.environment = environment
        do {
            try process.run()
        } catch {
            return nil
        }

        let timeoutWork = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + timeout,
            execute: timeoutWork
        )
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeoutWork.cancel()
        guard process.terminationReason == .exit,
              process.terminationStatus == 0 else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }
}
