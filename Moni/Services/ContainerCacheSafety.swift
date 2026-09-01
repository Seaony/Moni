import Darwin
import Foundation

nonisolated enum ContainerCacheSafety {
    private enum LsofMode {
        case direct
        case sudo
    }

    private struct FileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
        let kind: mode_t
    }

    private struct CommandResult {
        let status: Int32
        let output: String
        let timedOut: Bool
    }

    static func isConclusivelyIdle(
        at rawPath: String,
        commandTimeout: TimeInterval = 5
    ) -> Bool {
        let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
        guard let mode = completeLsofMode(commandTimeout: commandTimeout),
              let targetBefore = fileIdentity(at: path),
              targetBefore.kind != mode_t(S_IFLNK) else {
            return false
        }

        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL.path
        guard let parentBefore = fileIdentity(at: parent) else { return false }

        let arguments: [String]
        if targetBefore.kind == mode_t(S_IFDIR) {
            arguments = ["-F", "pfn", "+D", path]
        } else {
            arguments = ["-F", "pfn", "--", path]
        }
        let result = runLsof(mode: mode, arguments: arguments, timeout: commandTimeout)
        guard !result.timedOut else { return false }
        if result.status == 0 || containsFieldRecord(result.output) {
            return false
        }
        guard result.status == 1,
              result.output.isEmpty,
              fileIdentity(at: path) == targetBefore,
              fileIdentity(at: parent) == parentBefore else {
            return false
        }
        return true
    }

    static func hasNoVisibleOpenHandles(
        at rawPath: String,
        commandTimeout: TimeInterval = 5
    ) -> Bool {
        let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
        guard FileManager.default.isExecutableFile(atPath: "/usr/sbin/lsof"),
              let targetBefore = fileIdentity(at: path),
              targetBefore.kind != mode_t(S_IFLNK) else {
            return false
        }

        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL.path
        guard let parentBefore = fileIdentity(at: parent) else { return false }

        let arguments = targetBefore.kind == mode_t(S_IFDIR)
            ? ["-F", "pfn", "+D", path]
            : ["-F", "pfn", "--", path]
        let result = run("/usr/sbin/lsof", arguments: arguments, timeout: commandTimeout)
        guard !result.timedOut else { return false }
        if result.status == 0 || containsFieldRecord(result.output) {
            return false
        }
        return result.status == 1
            && result.output.isEmpty
            && fileIdentity(at: path) == targetBefore
            && fileIdentity(at: parent) == parentBefore
    }

    private static func completeLsofMode(commandTimeout: TimeInterval) -> LsofMode? {
        let executable = "/usr/sbin/lsof"
        guard FileManager.default.isExecutableFile(atPath: executable) else { return nil }

        let direct = run(
            executable,
            arguments: ["-F", "pu", "-p", "1"],
            timeout: commandTimeout
        )
        if confirmsRootVisibility(direct) {
            return .direct
        }

        let sudo = "/usr/bin/sudo"
        guard FileManager.default.isExecutableFile(atPath: sudo) else { return nil }
        let privileged = run(
            sudo,
            arguments: ["-n", executable, "-F", "pu", "-p", "1"],
            timeout: commandTimeout
        )
        return confirmsRootVisibility(privileged) ? .sudo : nil
    }

    private static func confirmsRootVisibility(_ result: CommandResult) -> Bool {
        guard !result.timedOut, result.status == 0 else { return false }
        let records = Set(result.output.split(whereSeparator: \.isNewline).map(String.init))
        return records.contains("p1") && records.contains("u0")
    }

    private static func containsFieldRecord(_ output: String) -> Bool {
        output.split(whereSeparator: \.isNewline).contains { line in
            guard let first = line.first else { return false }
            return first == "p" || first == "f" || first == "n"
        }
    }

    private static func runLsof(
        mode: LsofMode,
        arguments: [String],
        timeout: TimeInterval
    ) -> CommandResult {
        switch mode {
        case .direct:
            return run("/usr/sbin/lsof", arguments: arguments, timeout: timeout)
        case .sudo:
            return run(
                "/usr/bin/sudo",
                arguments: ["-n", "/usr/sbin/lsof"] + arguments,
                timeout: timeout
            )
        }
    }

    private static func run(
        _ executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) -> CommandResult {
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
            return CommandResult(status: -1, output: error.localizedDescription, timedOut: false)
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
        return CommandResult(
            status: process.terminationStatus,
            output: String(decoding: data, as: UTF8.self),
            timedOut: process.terminationReason == .uncaughtSignal
                && process.terminationStatus == SIGTERM
        )
    }

    private static func fileIdentity(at path: String) -> FileIdentity? {
        var value = stat()
        let result = path.withCString { lstat($0, &value) }
        guard result == 0 else { return nil }
        return FileIdentity(
            device: UInt64(value.st_dev),
            inode: UInt64(value.st_ino),
            kind: value.st_mode & mode_t(S_IFMT)
        )
    }
}
