import Foundation

nonisolated enum ClaudeDesktopQuotaReader {
    private struct CacheRecord {
        let url: URL
        let modifiedAt: Date
        let size: Int

        var signature: String {
            "\(url.path)|\(modifiedAt.timeIntervalSince1970.bitPattern)|\(size)"
        }
    }

    private struct Candidate: Codable, Equatable {
        let path: String
        let modifiedAt: Date
        let size: Int
    }

    private struct Snapshot: Codable, Equatable {
        let windows: [AIQuotaWindow]
        let updatedAt: Date
    }

    private struct State: Codable, Equatable {
        var version = 1
        var candidate: Candidate?
        var snapshot: Snapshot?
        var scanModifiedAt: Date = .distantPast
        var scanBoundary: [String] = []
        var lastFullScanAt: Date = .distantPast
    }

    private static let fullScanInterval: TimeInterval = 6 * 60 * 60
    private static let retryScanInterval: TimeInterval = 5 * 60
    private static let staleInterval: TimeInterval = 30 * 60
    private static let fileSizeLimit = 16 * 1024 * 1024
    private static let zstdMagic = Data([0x28, 0xb5, 0x2f, 0xfd])

    nonisolated static func fetch(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        now: Date = Date()
    ) -> AIQuotaFetchResult? {
        let records = cacheRecords(homeDirectory: homeDirectory)
        let recordsByPath = Dictionary(uniqueKeysWithValues: records.map { ($0.url.path, $0) })
        let original = loadState(homeDirectory: homeDirectory)
        var state = original
        let initialScan = state.scanModifiedAt == .distantPast
        let boundary = Set(state.scanBoundary)
        let changed = records.filter {
            $0.modifiedAt > state.scanModifiedAt
                || ($0.modifiedAt == state.scanModifiedAt && !boundary.contains($0.signature))
        }
        var inspected: Set<String> = []
        var selected: (CacheRecord, Snapshot)?

        func inspect(_ record: CacheRecord) -> (CacheRecord, Snapshot)? {
            inspected.insert(record.url.path)
            return parse(record).map { (record, $0) }
        }

        for record in changed {
            if let match = inspect(record) {
                selected = match
                break
            }
        }

        var candidateInvalid = false
        if selected == nil, let candidate = state.candidate {
            if let record = recordsByPath[candidate.path] {
                let changedCandidate = record.modifiedAt != candidate.modifiedAt || record.size != candidate.size
                if changedCandidate, !inspected.contains(record.url.path) {
                    selected = inspect(record)
                    candidateInvalid = selected == nil
                } else if changedCandidate {
                    candidateInvalid = true
                }
            } else {
                candidateInvalid = true
            }
        }

        if initialScan {
            state.lastFullScanAt = now
        }
        let retryInterval = state.snapshot == nil ? retryScanInterval : fullScanInterval
        let needsFullScan = candidateInvalid || now.timeIntervalSince(state.lastFullScanAt) >= retryInterval
        if selected == nil, needsFullScan {
            for record in records where !inspected.contains(record.url.path) {
                if let match = inspect(record) {
                    selected = match
                    break
                }
            }
            state.lastFullScanAt = now
        }

        if let (record, snapshot) = selected {
            state.candidate = Candidate(
                path: record.url.path,
                modifiedAt: record.modifiedAt,
                size: record.size
            )
            state.snapshot = snapshot
        } else if candidateInvalid {
            state.candidate = nil
        }

        if let newest = records.first {
            state.scanModifiedAt = newest.modifiedAt
            state.scanBoundary = records
                .prefix { $0.modifiedAt == newest.modifiedAt }
                .map(\.signature)
        } else {
            state.scanModifiedAt = .distantPast
            state.scanBoundary = []
        }
        if state != original {
            persistState(state, homeDirectory: homeDirectory)
        }

        guard let snapshot = state.snapshot,
            now.timeIntervalSince(snapshot.updatedAt) <= staleInterval,
            now.timeIntervalSince(snapshot.updatedAt) >= -300
        else { return nil }
        let windows = snapshot.windows.filter { $0.resetsAt.map { $0 > now } ?? true }
        guard !windows.isEmpty else { return nil }
        return AIQuotaFetchResult(planName: nil, windows: windows, message: nil)
    }

    private nonisolated static func cacheRecords(homeDirectory: URL) -> [CacheRecord] {
        let directory = homeDirectory.appending(
            path: "Library/Application Support/Claude/Cache/Cache_Data",
            directoryHint: .isDirectory
        )
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return urls.compactMap { url in
            guard url.lastPathComponent.hasSuffix("_0"),
                let values = try? url.resourceValues(forKeys: keys),
                values.isRegularFile == true,
                let modifiedAt = values.contentModificationDate,
                let size = values.fileSize
            else { return nil }
            return CacheRecord(url: url.resolvingSymlinksInPath(), modifiedAt: modifiedAt, size: size)
        }.sorted {
            if $0.modifiedAt == $1.modifiedAt { return $0.url.path > $1.url.path }
            return $0.modifiedAt > $1.modifiedAt
        }
    }

    private nonisolated static func parse(_ record: CacheRecord) -> Snapshot? {
        guard record.size > 0, record.size <= fileSizeLimit,
            let data = try? Data(contentsOf: record.url, options: .mappedIfSafe),
            data.range(of: Data("organizations/".utf8)) != nil,
            data.range(of: Data("/usage".utf8)) != nil,
            let magic = data.range(of: zstdMagic),
            let decompressed = MoniZstdDecompressFirstFrame(Data(data[magic.lowerBound...])),
            let json = try? JSONSerialization.jsonObject(with: decompressed) as? [String: Any]
        else { return nil }

        var windows: [AIQuotaWindow] = []
        appendWindow(
            json["five_hour"],
            id: "claude-five-hour",
            label: "5-hour window",
            minutes: 300,
            to: &windows
        )
        appendWindow(
            json["seven_day"],
            id: "claude-weekly",
            label: "Weekly",
            minutes: 10_080,
            to: &windows
        )
        appendWindow(
            json["seven_day_opus"],
            id: "claude-opus",
            label: "Opus only",
            minutes: 10_080,
            to: &windows
        )
        appendWindow(
            json["seven_day_sonnet"],
            id: "claude-sonnet",
            label: "Sonnet only",
            minutes: 10_080,
            to: &windows
        )
        appendScopedWindows(json["limits"], to: &windows)
        guard !windows.isEmpty else { return nil }
        return Snapshot(windows: windows, updatedAt: record.modifiedAt)
    }

    private nonisolated static func appendWindow(
        _ value: Any?,
        id: String,
        label: String,
        minutes: Int,
        to windows: inout [AIQuotaWindow]
    ) {
        guard let raw = value as? [String: Any],
            let usedPercent = (raw["utilization"] as? NSNumber)?.doubleValue
        else { return }
        windows.append(
            AIQuotaWindow(
                id: id,
                label: label,
                usedPercent: usedPercent,
                windowMinutes: minutes,
                resetsAt: isoDate(raw["resets_at"] as? String)
            )
        )
    }

    private nonisolated static func appendScopedWindows(_ value: Any?, to windows: inout [AIQuotaWindow]) {
        guard let limits = value as? [[String: Any]] else { return }
        for (index, limit) in limits.enumerated() {
            guard limit["kind"] as? String == "weekly_scoped",
                let usedPercent = (limit["percent"] as? NSNumber)?.doubleValue
            else { continue }
            let scope = limit["scope"] as? [String: Any]
            let model = scope?["model"] as? [String: Any]
            let name = model?["display_name"] as? String
                ?? model?["id"] as? String
                ?? "Model"
            windows.append(
                AIQuotaWindow(
                    id: "claude-scoped-\(index)-\(name)",
                    label: "\(name) only",
                    usedPercent: usedPercent,
                    windowMinutes: 10_080,
                    resetsAt: isoDate(limit["resets_at"] as? String)
                )
            )
        }
    }

    private nonisolated static func isoDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private nonisolated static func loadState(homeDirectory: URL) -> State {
        guard let data = try? Data(contentsOf: stateURL(homeDirectory: homeDirectory)),
            let state = try? JSONDecoder().decode(State.self, from: data),
            state.version == 1
        else { return State() }
        return state
    }

    private nonisolated static func persistState(_ state: State, homeDirectory: URL) {
        let url = stateURL(homeDirectory: homeDirectory)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(state).write(to: url, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        } catch {
            return
        }
    }

    private nonisolated static func stateURL(homeDirectory: URL) -> URL {
        homeDirectory
            .appending(path: "Library/Application Support/Moni", directoryHint: .isDirectory)
            .appending(path: "claude-quota-cache-v1.json")
    }
}
