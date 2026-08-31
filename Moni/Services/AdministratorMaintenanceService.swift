import Foundation

nonisolated enum SpotlightIndexStatus: Sendable {
    case enabled
    case disabled
    case unavailable
    case failed
}

nonisolated struct SystemMaintenanceSnapshot: Sendable {
    let spotlightStatus: SpotlightIndexStatus
}

nonisolated struct SystemMaintenanceResult: Sendable {
    let dnsCacheFlushed: Bool
    let spotlightStatus: SpotlightIndexStatus
}

nonisolated enum AdministratorMaintenanceService {
    private struct CommandOutput: Sendable {
        let status: Int32
        let output: String
    }

    private static let scriptExecutable = "/usr/bin/osascript"
    private static let metadataUtilityExecutable = "/usr/bin/mdutil"

    static func scanSystemMaintenance() async -> SystemMaintenanceSnapshot {
        await Task.detached(priority: .utility) {
            SystemMaintenanceSnapshot(spotlightStatus: inspectSpotlightIndex())
        }.value
    }

    static func runSystemMaintenance() async -> SystemMaintenanceResult {
        await Task.detached(priority: .userInitiated) {
            let command = "/usr/bin/dscacheutil -flushcache && /usr/bin/killall -HUP mDNSResponder"
            let dnsCacheFlushed = runPrivileged(command, timeout: 30)
            return SystemMaintenanceResult(
                dnsCacheFlushed: dnsCacheFlushed,
                spotlightStatus: inspectSpotlightIndex()
            )
        }.value
    }

    private static func inspectSpotlightIndex() -> SpotlightIndexStatus {
        guard FileManager.default.isExecutableFile(atPath: metadataUtilityExecutable) else {
            return .unavailable
        }
        let result = run(
            metadataUtilityExecutable,
            arguments: ["-s", "/"],
            timeout: 8
        )
        guard result.status == 0 else { return .failed }
        return result.output.localizedCaseInsensitiveContains("Indexing disabled")
            ? .disabled
            : .enabled
    }

    private static func runPrivileged(
        _ shellCommand: String,
        timeout: TimeInterval
    ) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: scriptExecutable) else { return false }
        let escaped = shellCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        return run(scriptExecutable, arguments: ["-e", script], timeout: timeout).status == 0
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
        process.standardError = outputPipe
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        process.environment = environment
        do {
            try process.run()
        } catch {
            return CommandOutput(status: -1, output: error.localizedDescription)
        }
        let timeoutWork = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeoutWork.cancel()
        return CommandOutput(
            status: process.terminationStatus,
            output: String(decoding: data, as: UTF8.self)
        )
    }
}
