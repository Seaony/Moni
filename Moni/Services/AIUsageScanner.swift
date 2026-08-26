import Foundation

actor AIUsageScanner {
    private struct TokenValues: Hashable {
        var input: UInt64 = 0
        var cacheRead: UInt64 = 0
        var cacheWrite: UInt64 = 0
        var output: UInt64 = 0
        var reasoning: UInt64 = 0

        var normalized: TokenValues {
            let read = min(cacheRead, input)
            let write = min(cacheWrite, input - read)
            return TokenValues(
                input: input - read - write,
                cacheRead: read,
                cacheWrite: write,
                output: output,
                reasoning: min(reasoning, output)
            )
        }

        func delta(from previous: TokenValues?) -> TokenValues {
            guard let previous else { return self }
            return TokenValues(
                input: input >= previous.input ? input - previous.input : 0,
                cacheRead: cacheRead >= previous.cacheRead ? cacheRead - previous.cacheRead : 0,
                cacheWrite: cacheWrite >= previous.cacheWrite ? cacheWrite - previous.cacheWrite : 0,
                output: output >= previous.output ? output - previous.output : 0,
                reasoning: reasoning >= previous.reasoning ? reasoning - previous.reasoning : 0
            )
        }
    }

    private struct UsageEvent {
        let date: Date
        let model: String
        let tokens: TokenValues
        let cacheWrite1h: UInt64
        let costUSD: Double?
    }

    private struct ModelTotals {
        var totalTokens: UInt64 = 0
        var input: UInt64 = 0
        var output: UInt64 = 0
        var cacheRead: UInt64 = 0
        var cacheWrite: UInt64 = 0
        var reasoning: UInt64 = 0
        var requests = 0
        var cost: Double = 0
        var pricedRequests = 0

        mutating func add(_ event: UsageEvent) {
            totalTokens +=
                event.tokens.input + event.tokens.cacheRead + event.tokens.cacheWrite + event.tokens.output
            input += event.tokens.input
            output += event.tokens.output
            cacheRead += event.tokens.cacheRead
            cacheWrite += event.tokens.cacheWrite
            reasoning += event.tokens.reasoning
            requests += 1
            if let eventCost = event.costUSD {
                cost += eventCost
                pricedRequests += 1
            }
        }
    }

    private struct Totals {
        var values = ModelTotals()
        var sessions = 0
        var models: [String: ModelTotals] = [:]
        var lastUpdated: Date?

        mutating func add(_ event: UsageEvent) {
            values.add(event)
            models[event.model, default: ModelTotals()].add(event)
            if event.date > lastUpdated ?? .distantPast {
                lastUpdated = event.date
            }
        }
    }

    private struct DailyBucket {
        var tokens: UInt64 = 0
        var cost: Double = 0
        var requests = 0

        mutating func add(_ event: UsageEvent) {
            tokens +=
                event.tokens.input + event.tokens.cacheRead + event.tokens.cacheWrite + event.tokens.output
            cost += event.costUSD ?? 0
            requests += 1
        }
    }

    private struct CodexEventKey: Hashable {
        let total: TokenValues?
        let last: TokenValues?
    }

    private struct CodexEvent {
        let usage: UsageEvent
        let key: CodexEventKey?
    }

    private struct CodexSession {
        let path: String
        let size: Int64
        var sessionID: String?
        var parentID: String?
        var events: [CodexEvent] = []
        var quota: TimestampedQuota?
    }

    private struct TimestampedQuota {
        let date: Date
        let result: AIQuotaFetchResult
    }

    private struct CodexScanResult {
        let totals: Totals
        let quota: AIQuotaFetchResult?
    }

    private struct FileSignature: Equatable {
        let size: Int64
        let modifiedAt: Date
    }

    private struct CodexCacheEntry {
        let signature: FileSignature
        let session: CodexSession
    }

    private struct ClaudeCacheEntry {
        let signature: FileSignature
        let events: [ClaudeEvent]
    }

    private struct ClaudeEvent {
        let path: String
        let sessionID: String
        let messageID: String?
        let requestID: String?
        let eventID: String?
        let isSidechain: Bool
        let isSubagent: Bool
        let usage: UsageEvent

        var inFileKey: String? {
            if let messageID, let requestID { return "request:\(messageID):\(requestID)" }
            if let messageID { return "message:\(messageID)" }
            if let eventID { return "event:\(eventID)" }
            return nil
        }

    }

    private let fileManager = FileManager.default
    private let homeDirectory: URL
    private let calendar: Calendar
    private let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let fallbackFormatter = ISO8601DateFormatter()
    private var codexCache: [String: CodexCacheEntry] = [:]
    private var claudeCache: [String: ClaudeCacheEntry] = [:]
    private let recordNeedles = [
        Data(#""token_count""#.utf8),
        Data(#""turn_context""#.utf8),
        Data(#""session_meta""#.utf8),
    ]
    private let claudeUsageNeedle = Data(#""usage""#.utf8)

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        calendar: Calendar = .current
    ) {
        self.homeDirectory = homeDirectory
        self.calendar = calendar
    }

    func scan(days: Int = 30, includeQuotas: Bool = false, now: Date = Date()) async -> AIUsageSummary {
        let today = calendar.startOfDay(for: now)
        let start =
            calendar.date(byAdding: .day, value: -(max(1, days) - 1), to: today) ?? .distantPast
        let end = calendar.date(byAdding: .day, value: 1, to: today) ?? now
        return await scan(start: start, end: end, includeQuotas: includeQuotas, now: now)
    }

    func scan(range: AIUsageRange, includeQuotas: Bool = false, now: Date = Date()) async -> AIUsageSummary {
        let interval = range.interval(containing: now, calendar: calendar)
        return await scan(
            start: interval.start,
            end: interval.end,
            includeQuotas: includeQuotas,
            now: now
        )
    }

    private func scan(
        start: Date,
        end: Date,
        includeQuotas: Bool,
        now: Date
    ) async -> AIUsageSummary {
        var daily: [Date: DailyBucket] = [:]
        let codex = scanCodex(start: start, end: end, daily: &daily)
        let claude = scanClaude(start: start, end: end, daily: &daily)
        var quotas = includeQuotas ? await AIQuotaFetcher.fetchAll(homeDirectory: homeDirectory) : [:]
        if includeQuotas, quotas["Codex"]?.windows.isEmpty != false, let localQuota = codex.quota {
            quotas["Codex"] = localQuota
        }
        let providers = [
            provider("Claude", totals: claude, quota: quotas["Claude"]),
            provider("Codex", totals: codex.totals, quota: quotas["Codex"]),
        ].filter { $0.totalTokens > 0 || $0.sessionCount > 0 || !$0.quotaWindows.isEmpty }
        let lastDay = calendar.date(byAdding: .day, value: -1, to: end) ?? start
        return AIUsageSummary(
            providers: providers,
            daily: dailyUsage(from: start, through: lastDay, buckets: daily),
            scannedAt: now,
            quotaScannedAt: includeQuotas ? now : nil
        )
    }

    private func dailyUsage(
        from start: Date,
        through end: Date,
        buckets: [Date: DailyBucket]
    ) -> [DailyAIUsage] {
        var result: [DailyAIUsage] = []
        var date = start
        while date <= end {
            let bucket = buckets[date] ?? DailyBucket()
            result.append(
                DailyAIUsage(
                    date: date,
                    tokens: bucket.tokens,
                    costUSD: bucket.cost,
                    requestCount: bucket.requests
                ))
            guard let next = calendar.date(byAdding: .day, value: 1, to: date) else { break }
            date = next
        }
        return result
    }

    private func scanCodex(start: Date, end: Date, daily: inout [Date: DailyBucket]) -> CodexScanResult {
        let roots = [
            homeDirectory.appending(path: ".codex/sessions"),
            homeDirectory.appending(path: ".codex/archived_sessions"),
        ]
        let files = jsonlFiles(in: roots, modifiedAfter: nil, filenamePrefix: "rollout-")
        let paths = Set(files.map(\.path))
        codexCache = codexCache.filter { paths.contains($0.key) }
        let parsed = files.map(cachedCodexSession)
        let sessions = canonicalCodexSessions(parsed)
        let droppedPrefixes = replayedCodexPrefixes(sessions)
        var totals = Totals()

        for session in sessions {
            let droppedCount = droppedPrefixes[session.path] ?? 0
            var countedSession = false
            for event in session.events.dropFirst(droppedCount)
            where event.usage.date >= start && event.usage.date < end {
                totals.add(event.usage)
                addDaily(event.usage, to: &daily)
                countedSession = true
            }
            if countedSession { totals.sessions += 1 }
        }
        let quota = sessions.compactMap(\.quota).max { $0.date < $1.date }?.result
        return CodexScanResult(totals: totals, quota: quota)
    }

    private func parseCodexSession(_ url: URL) -> CodexSession {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        var session = CodexSession(path: url.path, size: size)
        var currentModel: String?
        var previousTotal: TokenValues?

        enumerateLines(in: url) { line in
            guard recordNeedles.contains(where: { line.range(of: $0) != nil }),
                let object = json(line),
                let type = object["type"] as? String,
                let payload = object["payload"] as? [String: Any]
            else { return }

            if type == "session_meta" {
                session.sessionID =
                    string(payload["id"])
                    ?? string(payload["session_id"])
                    ?? string(payload["sessionId"])
                    ?? session.sessionID
                session.parentID = codexParentID(payload) ?? session.parentID
                return
            }
            if type == "turn_context" {
                if let model = string(payload["model"]), !model.isEmpty {
                    currentModel = model
                }
                return
            }
            guard type == "event_msg",
                string(payload["type"]) == "token_count",
                let timestamp = date(object["timestamp"])
            else { return }

            if let rateLimits = payload["rate_limits"] as? [String: Any],
                let quota = codexLogQuota(from: rateLimits),
                timestamp > (session.quota?.date ?? .distantPast)
            {
                session.quota = TimestampedQuota(date: timestamp, result: quota)
            }

            guard let info = payload["info"] as? [String: Any] else { return }

            let total = (info["total_token_usage"] as? [String: Any]).map(tokenValues)
            let last = (info["last_token_usage"] as? [String: Any]).map(tokenValues)
            if let total, total == previousTotal { return }
            let rawDelta = last ?? total?.delta(from: previousTotal)
            previousTotal = total ?? previousTotal
            guard let rawDelta else { return }
            let tokens = rawDelta.normalized
            guard tokens.input + tokens.cacheRead + tokens.cacheWrite + tokens.output > 0 else { return }

            let model = currentModel ?? "unknown"
            let cost = AIUsagePricing.estimatedCostUSD(
                provider: .codex,
                model: model,
                date: timestamp,
                inputTokens: tokens.input,
                cacheReadTokens: tokens.cacheRead,
                cacheWriteTokens: tokens.cacheWrite,
                outputTokens: tokens.output
            )
            session.events.append(
                CodexEvent(
                    usage: UsageEvent(
                        date: timestamp,
                        model: AIUsagePricing.normalize(model, provider: .codex),
                        tokens: tokens,
                        cacheWrite1h: 0,
                        costUSD: cost
                    ),
                    key: total == nil && last == nil ? nil : CodexEventKey(total: total, last: last)
                ))
        }
        return session
    }

    private func cachedCodexSession(_ url: URL) -> CodexSession {
        guard let signature = fileSignature(url) else { return parseCodexSession(url) }
        if let cached = codexCache[url.path], cached.signature == signature {
            return cached.session
        }
        let session = parseCodexSession(url)
        codexCache[url.path] = CodexCacheEntry(signature: signature, session: session)
        return session
    }

    private func canonicalCodexSessions(_ sessions: [CodexSession]) -> [CodexSession] {
        var selected: [String: CodexSession] = [:]
        for session in sessions {
            let key =
                session.sessionID.map { "session:\($0)" }
                ?? "file:\(URL(fileURLWithPath: session.path).lastPathComponent)"
            guard let current = selected[key] else {
                selected[key] = session
                continue
            }
            if isMoreComplete(session, than: current) {
                selected[key] = session
            }
        }
        return selected.values.sorted { $0.path < $1.path }
    }

    private func isMoreComplete(_ candidate: CodexSession, than current: CodexSession) -> Bool {
        if candidate.events.count != current.events.count {
            return candidate.events.count > current.events.count
        }
        let candidateLastDate = candidate.events.last?.usage.date ?? .distantPast
        let currentLastDate = current.events.last?.usage.date ?? .distantPast
        if candidateLastDate != currentLastDate {
            return candidateLastDate > currentLastDate
        }
        return candidate.size > current.size
    }

    private func replayedCodexPrefixes(_ sessions: [CodexSession]) -> [String: Int] {
        let byID = Dictionary(
            uniqueKeysWithValues: sessions.compactMap { session in
                session.sessionID.map { ($0, session) }
            })
        var drops: [String: Int] = [:]

        for child in sessions {
            guard let parentID = child.parentID, let parent = byID[parentID] else { continue }
            let count = matchingPrefix(child.events, parent.events)
            if count > 0 { drops[child.path] = count }
        }

        for child in sessions where drops[child.path] == nil && child.events.count >= 2 {
            var best = 0
            for parent in sessions where parent.path != child.path && parent.events.count >= 2 {
                guard parent.events[0].usage.date < child.events[0].usage.date else { continue }
                best = max(best, matchingPrefix(child.events, parent.events))
            }
            if best >= 2 { drops[child.path] = best }
        }
        return drops
    }

    private func matchingPrefix(_ lhs: [CodexEvent], _ rhs: [CodexEvent]) -> Int {
        var count = 0
        while count < lhs.count, count < rhs.count,
            let left = lhs[count].key, let right = rhs[count].key, left == right
        {
            count += 1
        }
        return count
    }

    private func scanClaude(start: Date, end: Date, daily: inout [Date: DailyBucket]) -> Totals {
        let files = jsonlFiles(in: claudeRoots(), modifiedAfter: start)
        let paths = Set(files.map(\.path))
        claudeCache = claudeCache.filter { paths.contains($0.key) }
        let allEvents = files.flatMap(cachedClaudeEvents)
        let events = reconciledClaudeEvents(allEvents)
        var totals = Totals()
        var sessions: Set<String> = []

        for event in events where event.usage.date >= start && event.usage.date < end {
            totals.add(event.usage)
            addDaily(event.usage, to: &daily)
            sessions.insert(event.sessionID)
        }
        totals.sessions = sessions.count
        return totals
    }

    private func parseClaudeFile(_ url: URL) -> [ClaudeEvent] {
        var keyed: [String: ClaudeEvent] = [:]
        var unkeyed: [ClaudeEvent] = []

        enumerateLines(in: url) { line in
            guard line.range(of: claudeUsageNeedle) != nil,
                let object = json(line),
                string(object["type"]) == "assistant",
                let timestamp = date(object["timestamp"]),
                let message = object["message"] as? [String: Any],
                let usage = message["usage"] as? [String: Any],
                let rawModel = string(message["model"])
            else { return }

            let input = uint(usage["input_tokens"])
            let output = uint(usage["output_tokens"])
            let cacheRead = uint(usage["cache_read_input_tokens"])
            let cacheWrite = uint(usage["cache_creation_input_tokens"])
            let cacheWrite1h = min(
                cacheWrite,
                uint((usage["cache_creation"] as? [String: Any])?["ephemeral_1h_input_tokens"])
            )
            let tokens = TokenValues(
                input: input,
                cacheRead: cacheRead,
                cacheWrite: cacheWrite,
                output: output,
                reasoning: 0
            )
            guard input + output + cacheRead + cacheWrite > 0 else { return }

            let model = AIUsagePricing.normalize(rawModel, provider: .claude)
            let event = ClaudeEvent(
                path: url.path,
                sessionID: claudeSessionID(object, message: message)
                    ?? url.deletingPathExtension().lastPathComponent,
                messageID: string(message["id"]),
                requestID: string(object["requestId"]) ?? string(object["request_id"]),
                eventID: string(object["uuid"]),
                isSidechain: bool(object["isSidechain"]),
                isSubagent: url.path.contains("/subagents/"),
                usage: UsageEvent(
                    date: timestamp,
                    model: model,
                    tokens: tokens,
                    cacheWrite1h: cacheWrite1h,
                    costUSD: AIUsagePricing.estimatedCostUSD(
                        provider: .claude,
                        model: model,
                        date: timestamp,
                        inputTokens: input,
                        cacheReadTokens: cacheRead,
                        cacheWriteTokens: cacheWrite,
                        cacheWrite1hTokens: cacheWrite1h,
                        outputTokens: output
                    )
                )
            )
            if let key = event.inFileKey {
                if let previous = keyed[key] {
                    keyed[key] = preferredClaudeEvent(event, over: previous)
                } else {
                    keyed[key] = event
                }
            } else {
                unkeyed.append(event)
            }
        }
        return Array(keyed.values) + unkeyed
    }

    private func cachedClaudeEvents(_ url: URL) -> [ClaudeEvent] {
        guard let signature = fileSignature(url) else { return parseClaudeFile(url) }
        if let cached = claudeCache[url.path], cached.signature == signature {
            return cached.events
        }
        let events = parseClaudeFile(url)
        claudeCache[url.path] = ClaudeCacheEntry(signature: signature, events: events)
        return events
    }

    private func reconciledClaudeEvents(_ events: [ClaudeEvent]) -> [ClaudeEvent] {
        var selected: [ClaudeEvent] = []
        var exactIndexes: [String: Int] = [:]
        var messageIndexes: [String: [Int]] = [:]

        for event in events {
            let exactKey = event.inFileKey
            var selectedIndex = exactKey.flatMap { exactIndexes[$0] }
            if selectedIndex == nil, let messageID = event.messageID {
                selectedIndex = messageIndexes[messageID]?.first { index in
                    event.isSidechain || selected[index].isSidechain
                }
            }

            if let selectedIndex {
                selected[selectedIndex] = preferredClaudeEvent(event, over: selected[selectedIndex])
                if let exactKey { exactIndexes[exactKey] = selectedIndex }
                continue
            }

            let index = selected.count
            selected.append(event)
            if let exactKey { exactIndexes[exactKey] = index }
            if let messageID = event.messageID {
                messageIndexes[messageID, default: []].append(index)
            }
        }
        return selected
    }

    private func preferredClaudeEvent(_ candidate: ClaudeEvent, over current: ClaudeEvent)
        -> ClaudeEvent
    {
        if candidate.isSidechain != current.isSidechain {
            return candidate.isSidechain ? current : candidate
        }
        if candidate.isSubagent != current.isSubagent {
            return candidate.isSubagent ? current : candidate
        }
        let candidateTokens = eventTotal(candidate.usage)
        let currentTokens = eventTotal(current.usage)
        if candidateTokens != currentTokens {
            return candidateTokens > currentTokens ? candidate : current
        }
        return candidate.usage.date >= current.usage.date ? candidate : current
    }

    private func provider(
        _ name: String,
        totals: Totals,
        quota: AIQuotaFetchResult?
    ) -> AIProviderUsage {
        let models = totals.models.map { model, values in
            AIModelUsage(
                model: model,
                totalTokens: values.totalTokens,
                inputTokens: values.input,
                outputTokens: values.output,
                cacheReadTokens: values.cacheRead,
                cacheWriteTokens: values.cacheWrite,
                reasoningTokens: values.reasoning,
                requestCount: values.requests,
                estimatedCostUSD: values.pricedRequests == 0 ? nil : values.cost
            )
        }.sorted { lhs, rhs in
            if lhs.estimatedCostUSD != rhs.estimatedCostUSD {
                return lhs.estimatedCostUSD ?? -1 > rhs.estimatedCostUSD ?? -1
            }
            return lhs.totalTokens > rhs.totalTokens
        }
        let values = totals.values
        return AIProviderUsage(
            provider: name,
            totalTokens: values.totalTokens,
            inputTokens: values.input,
            outputTokens: values.output,
            cacheReadTokens: values.cacheRead,
            cacheWriteTokens: values.cacheWrite,
            reasoningTokens: values.reasoning,
            requestCount: values.requests,
            sessionCount: totals.sessions,
            estimatedCostUSD: values.pricedRequests == 0 ? nil : values.cost,
            unpricedRequestCount: values.requests - values.pricedRequests,
            models: models,
            lastUpdated: totals.lastUpdated,
            planName: quota?.planName,
            quotaWindows: quota?.windows ?? [],
            quotaMessage: quota?.message
        )
    }

    private func addDaily(_ event: UsageEvent, to daily: inout [Date: DailyBucket]) {
        daily[calendar.startOfDay(for: event.date), default: DailyBucket()].add(event)
    }

    private func eventTotal(_ event: UsageEvent) -> UInt64 {
        event.tokens.input + event.tokens.cacheRead + event.tokens.cacheWrite + event.tokens.output
    }

    private func tokenValues(_ values: [String: Any]) -> TokenValues {
        TokenValues(
            input: uint(values["input_tokens"]),
            cacheRead: uint(values["cached_input_tokens"]),
            cacheWrite: uint(values["cache_write_input_tokens"]),
            output: uint(values["output_tokens"]),
            reasoning: uint(values["reasoning_output_tokens"])
        )
    }

    private func codexParentID(_ payload: [String: Any]) -> String? {
        if let direct = string(payload["forked_from_id"])
            ?? string(payload["parent_thread_id"])
            ?? string(payload["parent_session_id"])
        {
            return direct
        }
        guard let source = payload["source"] as? [String: Any],
            let subagent = source["subagent"] as? [String: Any],
            let spawn = subagent["thread_spawn"] as? [String: Any]
        else { return nil }
        return string(spawn["parent_thread_id"])
    }

    private func codexLogQuota(from rateLimits: [String: Any]) -> AIQuotaFetchResult? {
        var windows: [AIQuotaWindow] = []
        for (key, suffix) in [("primary", "primary"), ("secondary", "secondary")] {
            guard let raw = rateLimits[key] as? [String: Any],
                let used = (raw["used_percent"] as? NSNumber)?.doubleValue
            else { continue }
            let minutes = (raw["window_minutes"] as? NSNumber)?.intValue
            let label: String
            switch minutes {
            case 300: label = "5-hour window"
            case 10_080: label = "Weekly"
            default: label = "Usage window"
            }
            let resetSeconds = (raw["resets_at"] as? NSNumber)?.doubleValue
            windows.append(
                AIQuotaWindow(
                    id: "codex-\(suffix)-\(minutes ?? 0)",
                    label: label,
                    usedPercent: used,
                    windowMinutes: minutes,
                    resetsAt: resetSeconds.map(Date.init(timeIntervalSince1970:))
                ))
        }
        guard !windows.isEmpty else { return nil }
        let plan = string(rateLimits["plan_type"])?
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
        return AIQuotaFetchResult(planName: plan, windows: windows, message: nil)
    }

    private func claudeSessionID(_ object: [String: Any], message: [String: Any]) -> String? {
        string(object["sessionId"])
            ?? string(object["session_id"])
            ?? string((object["metadata"] as? [String: Any])?["sessionId"])
            ?? string((message["metadata"] as? [String: Any])?["sessionId"])
    }

    private func claudeRoots() -> [URL] {
        var roots = [
            homeDirectory.appending(path: ".claude/projects"),
            homeDirectory.appending(path: ".config/claude/projects"),
        ]
        if let configuredRoot = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"],
            !configuredRoot.isEmpty
        {
            roots.append(URL(fileURLWithPath: configuredRoot).appending(path: "projects"))
        }
        let support = homeDirectory.appending(path: "Library/Application Support/Claude")
        for name in ["local-agent-mode-sessions", "claude-code-sessions"] {
            roots.append(contentsOf: nestedClaudeRoots(under: support.appending(path: name), maxDepth: 4))
        }
        var seen: Set<String> = []
        return roots.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private func nestedClaudeRoots(under root: URL, maxDepth: Int) -> [URL] {
        var found: [URL] = []
        var queue: [(URL, Int)] = [(root, 0)]
        var index = 0
        let skipped: Set<String> = [
            ".build", ".git", "build", "DerivedData", "node_modules", "outputs", "target",
        ]
        while index < queue.count {
            let (current, depth) = queue[index]
            index += 1
            let projects = current.appending(path: ".claude/projects")
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: projects.path, isDirectory: &isDirectory),
                isDirectory.boolValue
            {
                found.append(projects)
            }
            guard depth < maxDepth,
                let children = try? fileManager.contentsOfDirectory(
                    at: current,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsPackageDescendants]
                )
            else { continue }
            for child in children where !skipped.contains(child.lastPathComponent) {
                if (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    queue.append((child, depth + 1))
                }
            }
        }
        return found
    }

    private func jsonlFiles(
        in roots: [URL],
        modifiedAfter cutoff: Date?,
        filenamePrefix: String? = nil
    ) -> [URL] {
        var files: [URL] = []
        var seen: Set<String> = []
        for root in roots {
            guard
                let enumerator = fileManager.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                    options: [.skipsHiddenFiles]
                )
            else { continue }
            for case let url as URL in enumerator {
                guard url.pathExtension == "jsonl",
                    filenamePrefix.map({ url.lastPathComponent.hasPrefix($0) }) ?? true,
                    let values = try? url.resourceValues(forKeys: [
                        .contentModificationDateKey, .isRegularFileKey,
                    ]),
                    values.isRegularFile == true,
                    cutoff.map({ values.contentModificationDate ?? .distantPast >= $0 }) ?? true,
                    seen.insert(url.standardizedFileURL.path).inserted
                else { continue }
                files.append(url)
            }
        }
        return files
    }

    private func fileSignature(_ url: URL) -> FileSignature? {
        guard
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
            let modifiedAt = values.contentModificationDate,
            let size = values.fileSize
        else { return nil }
        return FileSignature(size: Int64(size), modifiedAt: modifiedAt)
    }

    private func enumerateLines(in url: URL, body: (Data) -> Void) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }

        var buffer = Data()
        while autoreleasepool(invoking: {
            guard let chunk = try? handle.read(upToCount: 256 * 1_024), !chunk.isEmpty else {
                return false
            }
            buffer.append(chunk)
            var lineStart = buffer.startIndex
            while let newline = buffer[lineStart...].firstIndex(of: 0x0A) {
                body(buffer[lineStart..<newline])
                lineStart = buffer.index(after: newline)
            }
            if lineStart > buffer.startIndex {
                buffer = Data(buffer[lineStart...])
            }
            return true
        }) {}
        if !buffer.isEmpty {
            autoreleasepool { body(buffer) }
        }
    }

    private func json(_ line: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
    }

    private func date(_ value: Any?) -> Date? {
        guard let string = string(value) else { return nil }
        return formatter.date(from: string) ?? fallbackFormatter.date(from: string)
    }

    private func string(_ value: Any?) -> String? {
        value as? String
    }

    private func bool(_ value: Any?) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        return false
    }

    private func uint(_ value: Any?) -> UInt64 {
        if let value = value as? UInt64 { return value }
        if let value = value as? Int { return UInt64(max(0, value)) }
        if let value = value as? NSNumber { return value.uint64Value }
        return 0
    }
}
