import Foundation

nonisolated enum TimeMachineSnapshotState: Sendable {
    case ready
    case none
    case busy
    case notConfigured
    case unavailable
    case failed
}

nonisolated struct TimeMachineSnapshotReport: Sendable {
    let state: TimeMachineSnapshotState
    let snapshotCount: Int
}

nonisolated enum TimeMachineSnapshotService {
    private struct CommandOutput: Sendable {
        let status: Int32
        let output: String
        let timedOut: Bool
    }

    private static let timeMachineExecutable = "/usr/bin/tmutil"
    private static let defaultsExecutable = "/usr/bin/defaults"

    static func scan() async -> TimeMachineSnapshotReport {
        await Task.detached(priority: .utility) {
            scanSynchronously()
        }.value
    }

    private static func scanSynchronously() -> TimeMachineSnapshotReport {
        guard FileManager.default.isExecutableFile(atPath: timeMachineExecutable),
              FileManager.default.isExecutableFile(atPath: defaultsExecutable) else {
            return TimeMachineSnapshotReport(state: .unavailable, snapshotCount: 0)
        }

        let configuration = run(
            defaultsExecutable,
            arguments: ["read", "/Library/Preferences/com.apple.TimeMachine", "AutoBackup"],
            timeout: 5
        )
        let configurationValue = configuration.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !configuration.timedOut,
              configuration.status == 0,
              configurationValue == "0" || configurationValue == "1" else {
            return TimeMachineSnapshotReport(state: .notConfigured, snapshotCount: 0)
        }

        let status = run(timeMachineExecutable, arguments: ["status"], timeout: 8)
        guard !status.timedOut, status.status == 0 else {
            return TimeMachineSnapshotReport(state: .failed, snapshotCount: 0)
        }
        guard status.output.range(
            of: #"(?:^|\s)"?Running"?\s*=\s*[01](?:\s*;|$)"#,
            options: .regularExpression
        ) != nil else {
            return TimeMachineSnapshotReport(state: .failed, snapshotCount: 0)
        }
        if status.output.range(
            of: #"(?:^|\s)"?Running"?\s*=\s*1(?:\s*;|$)"#,
            options: .regularExpression
        ) != nil {
            return TimeMachineSnapshotReport(state: .busy, snapshotCount: 0)
        }

        let snapshots = run(
            timeMachineExecutable,
            arguments: ["listlocalsnapshots", "/"],
            timeout: 10
        )
        guard !snapshots.timedOut, snapshots.status == 0 else {
            return TimeMachineSnapshotReport(state: .failed, snapshotCount: 0)
        }
        let pattern = #"com\.apple\.TimeMachine\.\d{4}-\d{2}-\d{2}-\d{6}"#
        let expression = try? NSRegularExpression(pattern: pattern)
        let range = NSRange(snapshots.output.startIndex..., in: snapshots.output)
        let count = expression?.matches(in: snapshots.output, range: range).count ?? 0
        return TimeMachineSnapshotReport(
            state: count > 0 ? .ready : .none,
            snapshotCount: count
        )
    }

    private static func run(
        _ executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) -> CommandOutput {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        process.environment = environment
        do {
            try process.run()
        } catch {
            return CommandOutput(status: -1, output: error.localizedDescription, timedOut: false)
        }

        let timeoutWork = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let timedOut = !timeoutWork.isCancelled && process.terminationReason == .uncaughtSignal
        timeoutWork.cancel()
        return CommandOutput(
            status: process.terminationStatus,
            output: String(decoding: data, as: UTF8.self),
            timedOut: timedOut
        )
    }
}
