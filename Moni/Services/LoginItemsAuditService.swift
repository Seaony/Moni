import Foundation

nonisolated enum LoginItemsAuditState: Sendable {
    case ready
    case unavailable
    case failed
}

nonisolated struct BrokenLoginItem: Identifiable, Sendable {
    let name: String
    let path: String

    var id: String { name + "|" + path }
}

nonisolated struct LoginItemsAuditSnapshot: Sendable {
    let state: LoginItemsAuditState
    let checkedCount: Int
    let brokenItems: [BrokenLoginItem]
}

nonisolated enum LoginItemsAuditService {
    private struct CommandOutput: Sendable {
        let status: Int32
        let output: String
    }

    private enum ApplicationResolution {
        case found
        case missing
        case unknown
    }

    private static let scriptExecutable = "/usr/bin/osascript"
    private static let metadataSearchExecutable = "/usr/bin/mdfind"
    private static let sudoExecutable = "/usr/bin/sudo"
    private static let backgroundItemsExecutable = "/usr/bin/sfltool"

    static func scan() async -> LoginItemsAuditSnapshot {
        await Task.detached(priority: .utility) {
            guard FileManager.default.isExecutableFile(atPath: scriptExecutable) else {
                return LoginItemsAuditSnapshot(state: .unavailable, checkedCount: 0, brokenItems: [])
            }
            let result = run(
                scriptExecutable,
                arguments: ["-e", loginItemsScript],
                timeout: 12
            )
            guard result.status == 0 else {
                return LoginItemsAuditSnapshot(state: .failed, checkedCount: 0, brokenItems: [])
            }

            let items = result.output.split(whereSeparator: \.isNewline).compactMap { line -> (String, String)? in
                let fields = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                guard let first = fields.first else { return nil }
                let name = String(first).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return nil }
                let path = fields.count > 1
                    ? String(fields[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                    : ""
                return (name, path)
            }

            var brokenItems: [BrokenLoginItem] = []
            for item in items {
                guard !Task.isCancelled else {
                    return LoginItemsAuditSnapshot(state: .failed, checkedCount: 0, brokenItems: [])
                }
                if resolveApplication(name: item.0, itemPath: item.1) == .missing {
                    brokenItems.append(BrokenLoginItem(name: item.0, path: item.1))
                }
            }
            return LoginItemsAuditSnapshot(
                state: .ready,
                checkedCount: items.count,
                brokenItems: brokenItems.sorted {
                    $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
            )
        }.value
    }

    private static func resolveApplication(
        name: String,
        itemPath: String
    ) -> ApplicationResolution {
        if !itemPath.isEmpty,
           FileManager.default.fileExists(atPath: itemPath) || isSymbolicLink(itemPath) {
            return .found
        }

        let noSpace = name.replacingOccurrences(of: " ", with: "")
        let stripped = noSpace.replacingOccurrences(
            of: #"(Client|Helper|Agent|Launcher|Service)$"#,
            with: "",
            options: .regularExpression
        )
        var variants = [name]
        if noSpace != name { variants.append(noSpace) }
        if stripped != noSpace { variants.append(stripped) }

        if !name.contains("'") && variants.contains(where: metadataSearchFindsApplication) {
            return .found
        }

        let filesystemResult = filesystemFindsApplication(
            names: variants,
            expectedName: name,
            expectedNoSpace: noSpace,
            expectedStripped: stripped
        )
        if filesystemResult == .found { return .found }
        if backgroundItemsDatabaseFinds(name) { return .found }
        return filesystemResult
    }

    private static func metadataSearchFindsApplication(named name: String) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: metadataSearchExecutable) else {
            return false
        }
        let result = run(
            metadataSearchExecutable,
            arguments: ["kMDItemFSName == '\(name).app'"],
            timeout: 5
        )
        return result.status == 0 && !result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func filesystemFindsApplication(
        names: [String],
        expectedName: String,
        expectedNoSpace: String,
        expectedStripped: String
    ) -> ApplicationResolution {
        let fileManager = FileManager.default
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        ]
        let expectedFileNames = Set(names.map { ($0 + ".app").lowercased() })
        var incomplete = false

        for root in roots where fileManager.fileExists(atPath: root.path) {
            var readFailed = false
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles],
                errorHandler: { _, _ in
                    readFailed = true
                    return true
                }
            ) else {
                incomplete = true
                continue
            }
            let rootDepth = root.pathComponents.count
            while let url = enumerator.nextObject() as? URL {
                let depth = url.pathComponents.count - rootDepth
                if depth > 6 {
                    enumerator.skipDescendants()
                    continue
                }
                guard url.pathExtension.caseInsensitiveCompare("app") == .orderedSame else {
                    continue
                }
                if expectedFileNames.contains(url.lastPathComponent.lowercased()) {
                    return .found
                }
                let infoURL = url.appendingPathComponent("Contents/Info.plist")
                guard let data = try? Data(contentsOf: infoURL, options: .mappedIfSafe),
                      let plist = try? PropertyListSerialization.propertyList(
                        from: data,
                        options: [],
                        format: nil
                      ) as? [String: Any] else {
                    incomplete = true
                    continue
                }
                for key in ["CFBundleDisplayName", "CFBundleName", "CFBundleExecutable"] {
                    guard let value = plist[key] as? String else { continue }
                    if loginItemNameMatches(
                        value,
                        expected: expectedName,
                        expectedNoSpace: expectedNoSpace,
                        expectedStripped: expectedStripped
                    ) {
                        return .found
                    }
                }
            }
            if readFailed { incomplete = true }
        }
        return incomplete ? .unknown : .missing
    }

    private static func loginItemNameMatches(
        _ actual: String,
        expected: String,
        expectedNoSpace: String,
        expectedStripped: String
    ) -> Bool {
        guard !actual.isEmpty else { return false }
        let actualNoSpace = actual.replacingOccurrences(of: " ", with: "")
        return actual == expected
            || actualNoSpace == expectedNoSpace
            || !expectedStripped.isEmpty && actualNoSpace == expectedStripped
    }

    private static func backgroundItemsDatabaseFinds(_ name: String) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: sudoExecutable),
              FileManager.default.isExecutableFile(atPath: backgroundItemsExecutable),
              run(sudoExecutable, arguments: ["-n", "true"], timeout: 3).status == 0 else {
            return false
        }
        let result = run(
            sudoExecutable,
            arguments: ["-n", backgroundItemsExecutable, "dumpbtm"],
            timeout: 10
        )
        guard result.status == 0 else { return false }
        return result.output.split(whereSeparator: \.isNewline).contains { line in
            let text = String(line)
            guard text.localizedCaseInsensitiveContains(name),
                  let range = text.range(of: #"/.*\.app"#, options: .regularExpression) else {
                return false
            }
            return FileManager.default.fileExists(atPath: String(text[range]))
        }
    }

    private static func isSymbolicLink(_ path: String) -> Bool {
        guard let type = try? FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType else {
            return false
        }
        return type == .typeSymbolicLink
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
            return CommandOutput(status: -1, output: "")
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

    private static let loginItemsScript = """
    set oldDelimiters to AppleScript's text item delimiters
    set tabChar to ASCII character 9
    set linefeedChar to ASCII character 10
    set outputLines to {}

    tell application "System Events"
        repeat with loginItem in login items
            set itemName to ""
            set itemPath to ""

            try
                set itemName to name of loginItem as text
            end try

            try
                set itemPath to POSIX path of (path of loginItem as alias)
            on error
                try
                    set itemPath to path of loginItem as text
                end try
            end try

            set end of outputLines to itemName & tabChar & itemPath
        end repeat
    end tell

    set AppleScript's text item delimiters to linefeedChar
    set outputText to outputLines as text
    set AppleScript's text item delimiters to oldDelimiters
    return outputText
    """
}
