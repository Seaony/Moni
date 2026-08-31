import Foundation

nonisolated enum NixGarbageCollectionState: Sendable {
    case ready
    case protected
    case unavailable
}

nonisolated enum NixGarbageCollectionOutcome: Sendable {
    case completed
    case protected
    case unavailable
    case failed
}

nonisolated enum NixGarbageCollectionService {
    private static let storePath = "/nix/store"
    private static let commandTimeout: TimeInterval = 300

    static func scan() -> NixGarbageCollectionState {
        guard FileManager.default.fileExists(atPath: storePath),
              collectorExecutable() != nil else {
            return .unavailable
        }
        return CleanupPreferences.isWhitelisted(storePath) ? .protected : .ready
    }

    static func collect() async -> NixGarbageCollectionOutcome {
        switch scan() {
        case .protected:
            return .protected
        case .unavailable:
            return .unavailable
        case .ready:
            break
        }
        guard let executable = collectorExecutable(),
              !CleanupPreferences.isWhitelisted(storePath) else {
            return collectorExecutable() == nil ? .unavailable : .protected
        }
        let succeeded = await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["--delete-older-than", "30d"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                return false
            }
            let deadline = Date().addingTimeInterval(commandTimeout)
            while process.isRunning, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            return process.terminationReason == .exit && process.terminationStatus == 0
        }.value
        return succeeded ? .completed : .failed
    }

    private static func collectorExecutable() -> String? {
        var paths = [
            "/nix/var/nix/profiles/default/bin/nix-collect-garbage",
            "/run/current-system/sw/bin/nix-collect-garbage",
            "/opt/homebrew/bin/nix-collect-garbage",
            "/usr/local/bin/nix-collect-garbage"
        ]
        if let environmentPath = ProcessInfo.processInfo.environment["PATH"] {
            paths.append(contentsOf: environmentPath.split(separator: ":").map {
                URL(fileURLWithPath: String($0), isDirectory: true)
                    .appendingPathComponent("nix-collect-garbage")
                    .standardizedFileURL.path
            })
        }
        var visited = Set<String>()
        return paths.first { candidate in
            let standardized = URL(fileURLWithPath: candidate).standardizedFileURL.path
            guard visited.insert(standardized).inserted else { return false }
            return FileManager.default.isExecutableFile(atPath: standardized)
        }
    }
}
