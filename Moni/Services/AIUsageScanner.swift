import Foundation
import SQLite3

actor AIUsageScanner {
    private struct TokenValues: Codable, Hashable {
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

    private struct UsageEvent: Codable {
        let date: Date
        let model: String
        let tokens: TokenValues
        let cacheWrite1h: UInt64
        let costUSD: Double?
        var requestCount = 1
        var reasoningCountsSeparately = false
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
                    + (event.reasoningCountsSeparately ? event.tokens.reasoning : 0)
            input += event.tokens.input
            output += event.tokens.output
            cacheRead += event.tokens.cacheRead
            cacheWrite += event.tokens.cacheWrite
            reasoning += event.tokens.reasoning
            requests += max(1, event.requestCount)
            if let eventCost = event.costUSD {
                cost += eventCost
                pricedRequests += max(1, event.requestCount)
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
        var providerTokens: [String: UInt64] = [:]
        var providerCosts: [String: Double] = [:]

        mutating func add(_ event: UsageEvent, provider: String) {
            let eventTokens =
                event.tokens.input + event.tokens.cacheRead + event.tokens.cacheWrite + event.tokens.output
                    + (event.reasoningCountsSeparately ? event.tokens.reasoning : 0)
            tokens += eventTokens
            cost += event.costUSD ?? 0
            requests += max(1, event.requestCount)
            providerTokens[provider, default: 0] += eventTokens
            providerCosts[provider, default: 0] += event.costUSD ?? 0
        }
    }

    private struct CodexEventKey: Codable, Hashable {
        let total: TokenValues?
        let last: TokenValues?
    }

    private struct CodexEvent: Codable {
        let usage: UsageEvent
        let key: CodexEventKey?
    }

    private struct CodexSession: Codable {
        let path: String
        var size: Int64
        var sessionID: String?
        var parentID: String?
        var events: [CodexEvent] = []
        var quota: TimestampedQuota?
    }

    private struct TimestampedQuota: Codable {
        let date: Date
        let result: AIQuotaFetchResult
    }

    private struct CodexScanResult {
        let totals: Totals
        let quota: AIQuotaFetchResult?
    }

    private struct FileSignature: Codable, Equatable {
        let size: Int64
        let modifiedAt: Date
    }

    private struct CodexCacheEntry: Codable {
        let signature: FileSignature
        let session: CodexSession
        let completeOffset: UInt64
        let currentModel: String?
        let previousTotal: TokenValues?
    }

    private struct ClaudeCacheEntry: Codable {
        let signature: FileSignature
        let events: [ClaudeEvent]
    }

    private struct GeminiFileSignature: Equatable {
        let database: FileSignature
        let writeAheadLog: FileSignature?
    }

    private struct GeminiCacheEntry {
        let signature: GeminiFileSignature
        let session: GeminiSession?
    }

    private struct ClaudeEvent: Codable {
        let path: String
        let sessionID: String
        let messageID: String?
        let requestID: String?
        let eventID: String?
        let isSidechain: Bool
        let usage: UsageEvent

        var inFileKey: String? {
            if let messageID, let requestID { return "request:\(messageID):\(requestID)" }
            if let messageID { return "message:\(messageID)" }
            if let eventID { return "event:\(eventID)" }
            return nil
        }

    }

    private struct QwenEvent {
        let requestID: String?
        let sessionID: String
        let usages: [UsageEvent]
    }

    private struct OpenCodeRecord {
        let id: String
        let sessionID: String
        let usage: UsageEvent
    }

    private struct KimiRecord {
        let key: String
        let usage: UsageEvent
    }

    private struct KimiWireGroup {
        var agentWires: [URL] = []
        var rootWire: URL?
    }

    private struct GeminiSession {
        let id: String
        let rank: Int
        let updatedAt: Date
        let modifiedAt: Date
        let events: [UsageEvent]
    }

    private struct DeepSeekRecord {
        let turn: Int
        let step: Int
        let priority: Int
        let usage: UsageEvent
    }

    private struct DeepSeekCacheEntry {
        let signature: FileSignature
        let sessionID: String
        let records: [DeepSeekRecord]
    }

    private struct DeepSeekRecordKey: Hashable {
        let turn: Int
        let step: Int
    }

    private struct DeepSeekGlobalKey: Hashable {
        let sessionID: String
        let turn: Int
        let step: Int
    }

    private struct ProtobufField {
        let number: Int
        let wireType: Int
        let varint: UInt64?
        let data: Data?
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
    private var codexCache: [String: CodexCacheEntry]
    private var claudeCache: [String: ClaudeCacheEntry]
    private var loadedPersistentCaches = false
    private var codexCacheDirty = false
    private var claudeCacheDirty = false
    private var geminiCache: [String: GeminiCacheEntry] = [:]
    private var deepSeekCache: [String: DeepSeekCacheEntry] = [:]
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
        codexCache = [:]
        claudeCache = [:]
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
        loadPersistentCachesIfNeeded()
        var daily: [Date: DailyBucket] = [:]
        let codex = scanCodex(start: start, end: end, daily: &daily)
        let claude = scanClaude(start: start, end: end, daily: &daily)
        let qwen = scanQwen(start: start, end: end, daily: &daily)
        let openCode = scanOpenCode(start: start, end: end, daily: &daily)
        let kimi = scanKimi(start: start, end: end, daily: &daily)
        let gemini = scanGemini(start: start, end: end, daily: &daily)
        let deepSeek = scanDeepSeek(start: start, end: end, daily: &daily)
        var quotas: [String: AIQuotaFetchResult] = [:]
        if let localQuota = codex.quota {
            quotas["Codex"] = localQuota
        }
        if let localQuota = ClaudeDesktopQuotaReader.fetch(homeDirectory: homeDirectory, now: now) {
            quotas["Claude"] = localQuota
        }
        let coreProviders = [
            provider("Claude", totals: claude, quota: quotas["Claude"]),
            provider("Codex", totals: codex.totals, quota: quotas["Codex"]),
        ]
        let detectedProviders = [
            provider("Qwen Code", totals: qwen, quota: nil),
            provider("OpenCode", totals: openCode, quota: nil),
            provider("Kimi Code", totals: kimi, quota: nil),
            provider("Gemini CLI", totals: gemini, quota: nil),
            provider("DeepSeek Harness", totals: deepSeek, quota: nil),
        ].filter { $0.totalTokens > 0 || $0.sessionCount > 0 || !$0.quotaWindows.isEmpty }
        let providers = coreProviders + detectedProviders
        let lastDay = calendar.date(byAdding: .day, value: -1, to: end) ?? start
        let summary = AIUsageSummary(
            providers: providers,
            daily: dailyUsage(from: start, through: lastDay, buckets: daily),
            scannedAt: now,
            quotaScannedAt: nil
        )
        return includeQuotas ? await refreshQuotas(in: summary, now: now) : summary
    }

    func refreshQuotas(
        in summary: AIUsageSummary,
        now: Date = Date(),
        allowClaudeKeychainPrompt: Bool = false
    ) async -> AIUsageSummary {
        let fetched = await AIQuotaFetcher.fetchAll(
            homeDirectory: homeDirectory,
            allowClaudeKeychainPrompt: allowClaudeKeychainPrompt
        )
        var refreshed = summary
        refreshed.providers = summary.providers.map { provider in
            guard let quota = fetched[provider.provider],
                !quota.windows.isEmpty || provider.quotaWindows.isEmpty
            else { return provider }
            return replacingQuota(of: provider, with: quota)
        }
        refreshed.quotaScannedAt = now
        return refreshingWeeklyWindowCosts(in: refreshed, now: now)
    }

    func refreshWeeklyWindowCosts(
        in summary: AIUsageSummary,
        now: Date = Date()
    ) -> AIUsageSummary {
        refreshingWeeklyWindowCosts(in: summary, now: now)
    }

    private func refreshingWeeklyWindowCosts(
        in summary: AIUsageSummary,
        now: Date
    ) -> AIUsageSummary {
        var refreshed = summary
        var costs: [String: Double] = [:]

        for provider in summary.providers {
            guard let quota = provider.quotaWindows.first(where: {
                $0.windowMinutes == 10_080 || $0.label.localizedCaseInsensitiveContains("week")
            }),
                let resetsAt = quota.resetsAt,
                let windowMinutes = quota.windowMinutes,
                resetsAt > now
            else { continue }

            let windowStart = resetsAt.addingTimeInterval(-TimeInterval(windowMinutes * 60))
            if let cost = exactProviderCostUSD(
                provider.provider,
                start: windowStart,
                end: min(now, resetsAt)
            ) {
                costs[provider.provider] = cost
            }
        }

        refreshed.weeklyWindowCostsUSD = costs.isEmpty ? nil : costs
        return refreshed
    }

    private func exactProviderCostUSD(
        _ provider: String,
        start: Date,
        end: Date
    ) -> Double? {
        guard end > start else { return nil }
        loadPersistentCachesIfNeeded()
        var daily: [Date: DailyBucket] = [:]
        let totals: Totals

        switch provider {
        case "Codex":
            totals = scanCodex(start: start, end: end, daily: &daily).totals
        case "Claude":
            totals = scanClaude(start: start, end: end, daily: &daily)
        default:
            return nil
        }

        guard totals.values.requests > 0,
            totals.values.pricedRequests == totals.values.requests,
            totals.values.cost > 0
        else { return nil }
        return totals.values.cost
    }

    private func replacingQuota(
        of provider: AIProviderUsage,
        with quota: AIQuotaFetchResult
    ) -> AIProviderUsage {
        AIProviderUsage(
            provider: provider.provider,
            totalTokens: provider.totalTokens,
            inputTokens: provider.inputTokens,
            outputTokens: provider.outputTokens,
            cacheReadTokens: provider.cacheReadTokens,
            cacheWriteTokens: provider.cacheWriteTokens,
            reasoningTokens: provider.reasoningTokens,
            requestCount: provider.requestCount,
            sessionCount: provider.sessionCount,
            estimatedCostUSD: provider.estimatedCostUSD,
            unpricedRequestCount: provider.unpricedRequestCount,
            models: provider.models,
            lastUpdated: provider.lastUpdated,
            planName: quota.planName ?? provider.planName,
            quotaWindows: quota.windows,
            quotaMessage: quota.message
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
                    requestCount: bucket.requests,
                    providers: Dictionary(uniqueKeysWithValues: bucket.providerTokens.map {
                        provider, tokens in
                        (
                            provider,
                            DailyAIProviderUsage(
                                tokens: tokens,
                                costUSD: bucket.providerCosts[provider] ?? 0
                            )
                        )
                    })
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
        let retainedCache = codexCache.filter { paths.contains($0.key) }
        if retainedCache.count != codexCache.count {
            codexCache = retainedCache
            codexCacheDirty = true
        }
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
                addDaily(event.usage, provider: "Codex", to: &daily)
                countedSession = true
            }
            if countedSession { totals.sessions += 1 }
        }
        let quota = sessions.compactMap(\.quota).max { $0.date < $1.date }?.result
        persistCodexCacheIfNeeded()
        return CodexScanResult(totals: totals, quota: quota)
    }

    private func parseCodexSession(
        _ url: URL,
        signature: FileSignature,
        continuing cached: CodexCacheEntry?
    ) -> CodexCacheEntry {
        let canContinue = cached.map {
            signature.size > $0.signature.size && $0.completeOffset <= UInt64($0.signature.size)
        } ?? false
        var session = canContinue
            ? cached!.session
            : CodexSession(path: url.path, size: signature.size)
        session.size = signature.size
        var currentModel = canContinue ? cached?.currentModel : nil
        var previousTotal = canContinue ? cached?.previousTotal : nil
        let startOffset = canContinue ? cached?.completeOffset ?? 0 : 0

        let completeOffset = enumerateCompleteLines(in: url, from: startOffset) { line in
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
        return CodexCacheEntry(
            signature: signature,
            session: session,
            completeOffset: completeOffset,
            currentModel: currentModel,
            previousTotal: previousTotal
        )
    }

    private func cachedCodexSession(_ url: URL) -> CodexSession {
        guard let signature = fileSignature(url) else {
            return parseCodexSession(
                url,
                signature: FileSignature(size: 0, modifiedAt: .distantPast),
                continuing: nil
            ).session
        }
        if let cached = codexCache[url.path], cached.signature == signature {
            return cached.session
        }
        let entry = parseCodexSession(url, signature: signature, continuing: codexCache[url.path])
        codexCache[url.path] = entry
        codexCacheDirty = true
        return entry.session
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
        let allEvents = files.flatMap(cachedClaudeEvents)
        let events = reconciledClaudeEvents(allEvents)
        var totals = Totals()
        var sessions: Set<String> = []

        for event in events where event.usage.date >= start && event.usage.date < end {
            totals.add(event.usage)
            addDaily(event.usage, provider: "Claude", to: &daily)
            sessions.insert(event.path)
        }
        totals.sessions = sessions.count
        persistClaudeCacheIfNeeded()
        return totals
    }

    private func scanQwen(start: Date, end: Date, daily: inout [Date: DailyBucket]) -> Totals {
        var requests: [String: QwenEvent] = [:]
        for url in qwenRequestFiles() {
            enumerateLines(in: url) { line in
                guard let record = json(line),
                    let event = qwenRequestEvent(record),
                    let requestID = event.requestID
                else { return }
                requests[requestID] = event
            }
        }

        let requestSessions = Set(requests.values.map(\.sessionID))
        var summaries: [String: QwenEvent] = [:]
        let summaryURL = homeDirectory.appending(path: ".qwen/usage_record.jsonl")
        enumerateLines(in: summaryURL) { line in
            guard let record = json(line), let event = qwenSummaryEvent(record) else { return }
            summaries[event.sessionID] = event
        }

        let events = Array(requests.values)
            + summaries.values.filter { !requestSessions.contains($0.sessionID) }
        var totals = Totals()
        var sessions: Set<String> = []
        for event in events {
            var countedSession = false
            for usage in event.usages where usage.date >= start && usage.date < end {
                totals.add(usage)
                addDaily(usage, provider: "Qwen Code", to: &daily)
                countedSession = true
            }
            if countedSession { sessions.insert(event.sessionID) }
        }
        totals.sessions = sessions.count
        return totals
    }

    private func qwenRequestEvent(_ record: [String: Any]) -> QwenEvent? {
        guard uint(record["schemaVersion"]) == 1,
            let requestID = string(record["id"]), !requestID.isEmpty,
            let sessionID = string(record["sessionId"]), !sessionID.isEmpty,
            let timestamp = flexibleDate(record["timestamp"])
                ?? localDayDate(string(record["localDate"])),
            let model = string(record["model"]), !model.isEmpty
        else { return nil }

        return QwenEvent(
            requestID: requestID,
            sessionID: sessionID,
            usages: [qwenUsageEvent(model: model, values: record, date: timestamp, requestCount: 1)]
        )
    }

    private func qwenSummaryEvent(_ record: [String: Any]) -> QwenEvent? {
        guard uint(record["version"]) == 1,
            let sessionID = string(record["sessionId"]), !sessionID.isEmpty,
            let timestamp = flexibleDate(record["timestamp"])
                ?? flexibleDate(record["startTime"]),
            let models = record["models"] as? [String: Any]
        else { return nil }

        let usages = models.compactMap { model, rawValues -> UsageEvent? in
            guard let values = rawValues as? [String: Any] else { return nil }
            return qwenUsageEvent(
                model: model,
                values: values,
                date: timestamp,
                requestCount: max(1, Int(uint(values["requests"])))
            )
        }
        guard !usages.isEmpty else { return nil }
        return QwenEvent(requestID: nil, sessionID: sessionID, usages: usages)
    }

    private func qwenUsageEvent(
        model rawModel: String,
        values: [String: Any],
        date: Date,
        requestCount: Int
    ) -> UsageEvent {
        var inputTotal = uint(values["inputTokens"])
        var cached = uint(values["cachedTokens"])
        if inputTotal == 0, cached > 0 { inputTotal = cached }
        cached = min(cached, inputTotal)
        let input = inputTotal - cached
        let output = uint(values["outputTokens"])
        let reasoning = uint(values["thoughtsTokens"])
        let model = AIUsagePricing.normalize(rawModel, provider: .qwen)
        return UsageEvent(
            date: date,
            model: model,
            tokens: TokenValues(
                input: input,
                cacheRead: cached,
                output: output,
                reasoning: reasoning
            ),
            cacheWrite1h: 0,
            costUSD: AIUsagePricing.estimatedCostUSD(
                provider: .qwen,
                model: model,
                date: date,
                inputTokens: input,
                cacheReadTokens: cached,
                cacheWriteTokens: 0,
                outputTokens: output + reasoning
            ),
            requestCount: requestCount,
            reasoningCountsSeparately: true
        )
    }

    private func qwenRequestFiles() -> [URL] {
        qwenRuntimeDirectories().flatMap { root -> [URL] in
            let usage = root.appending(path: "usage")
            guard let files = try? fileManager.contentsOfDirectory(
                at: usage,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { return [] }
            return files.filter {
                $0.pathExtension == "jsonl" && $0.lastPathComponent.hasPrefix("token-usage-")
            }
        }.sorted { $0.path < $1.path }
    }

    private func qwenRuntimeDirectories() -> [URL] {
        if let configured = ProcessInfo.processInfo.environment["QWEN_RUNTIME_DIR"],
            let url = qwenAbsoluteURL(configured)
        {
            return [url]
        }

        let defaultRoot = homeDirectory.appending(path: ".qwen")
        let settingsURL = defaultRoot.appending(path: "settings.json")
        if let data = try? Data(contentsOf: settingsURL),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let advanced = root["advanced"] as? [String: Any],
            let configured = string(advanced["runtimeOutputDir"]),
            let url = qwenAbsoluteURL(configured)
        {
            return [url]
        }
        return [defaultRoot]
    }

    private func qwenAbsoluteURL(_ path: String) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "~" { return homeDirectory }
        if trimmed.hasPrefix("~/") {
            return homeDirectory.appending(path: String(trimmed.dropFirst(2)))
        }
        guard trimmed.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: trimmed).standardizedFileURL
    }

    private func scanDeepSeek(start: Date, end: Date, daily: inout [Date: DailyBucket]) -> Totals {
        let files = deepSeekFiles()
        let paths = Set(files.map(\.path))
        deepSeekCache = deepSeekCache.filter { paths.contains($0.key) }

        var flattened: [(path: String, sessionID: String, record: DeepSeekRecord)] = []
        for url in files {
            let entry = cachedDeepSeekFile(url)
            flattened.append(
                contentsOf: entry.records.map { (url.path, entry.sessionID, $0) }
            )
        }
        flattened.sort {
            if $0.record.usage.date != $1.record.usage.date {
                return $0.record.usage.date < $1.record.usage.date
            }
            return $0.path < $1.path
        }

        var totals = Totals()
        var sessions: Set<String> = []
        var seen: Set<DeepSeekGlobalKey> = []
        for item in flattened {
            let key = DeepSeekGlobalKey(
                sessionID: item.sessionID,
                turn: item.record.turn,
                step: item.record.step
            )
            guard seen.insert(key).inserted else { continue }
            let usage = item.record.usage
            guard usage.date >= start, usage.date < end else { continue }
            totals.add(usage)
            addDaily(usage, provider: "DeepSeek Harness", to: &daily)
            sessions.insert(item.sessionID)
        }
        totals.sessions = sessions.count
        return totals
    }

    private func cachedDeepSeekFile(_ url: URL) -> DeepSeekCacheEntry {
        guard let signature = fileSignature(url) else { return parseDeepSeekFile(url) }
        if let cached = deepSeekCache[url.path], cached.signature == signature {
            return cached
        }
        let entry = parseDeepSeekFile(url, signature: signature)
        deepSeekCache[url.path] = entry
        return entry
    }

    private func parseDeepSeekFile(
        _ url: URL,
        signature: FileSignature? = nil
    ) -> DeepSeekCacheEntry {
        let fallbackSignature = signature
            ?? FileSignature(size: 0, modifiedAt: .distantPast)
        let baseName = url.lastPathComponent
            .replacingOccurrences(of: ".jsonl.zstd", with: "")
            .replacingOccurrences(of: ".jsonl", with: "")
        var sessionID = baseName
        var currentModel = "deepseek-v4-pro"
        var currentProvider = "deepseek-official"
        var candidates: [DeepSeekRecordKey: DeepSeekRecord] = [:]

        guard let data = deepSeekLogData(url) else {
            return DeepSeekCacheEntry(
                signature: fallbackSignature,
                sessionID: sessionID,
                records: []
            )
        }
        enumerateLines(in: data) { line in
            guard let item = json(line), let type = string(item["type"]) else { return }
            if type == "session" {
                if let id = string(item["id"]), !id.isEmpty { sessionID = id }
                return
            }
            guard let values = item["data"] as? [String: Any] else { return }
            if type == "request/header" {
                guard let header = values["header"] as? [String: Any],
                    let config = header["config"] as? [String: Any]
                else { return }
                if let model = string(config["model"]), !model.isEmpty {
                    currentModel = model
                }
                if let provider = string(config["provider"]), !provider.isEmpty {
                    currentProvider = provider
                }
                return
            }
            guard
                let record = deepSeekRecord(
                    item,
                    values: values,
                    fallbackModel: currentModel,
                    fallbackProvider: currentProvider
                )
            else { return }
            let key = DeepSeekRecordKey(turn: record.turn, step: record.step)
            if record.priority >= candidates[key]?.priority ?? -1 {
                candidates[key] = record
            }
        }
        return DeepSeekCacheEntry(
            signature: fallbackSignature,
            sessionID: sessionID,
            records: candidates.values.sorted { $0.usage.date < $1.usage.date }
        )
    }

    private func deepSeekRecord(
        _ item: [String: Any],
        values: [String: Any],
        fallbackModel: String,
        fallbackProvider: String
    ) -> DeepSeekRecord? {
        guard let type = string(item["type"]),
            let timestamp = flexibleDate(item["time"]),
            let turn = nonnegativeInt(values["turn"]),
            let step = nonnegativeInt(values["step"])
        else { return nil }

        let usage: [String: Any]
        let priority: Int
        var model = fallbackModel
        var provider = fallbackProvider
        if type == "assistant/message" {
            guard let parsed = values["usage"] as? [String: Any] else { return nil }
            usage = parsed
            if let message = values["message"] as? [String: Any],
                let source = message["source"] as? [String: Any]
            {
                if let value = string(source["model"]), !value.isEmpty { model = value }
                if let value = string(source["provider"]), !value.isEmpty { provider = value }
            }
            priority = 2
        } else if type == "assistant/chunk" {
            guard let chunk = values["chunk"] as? [String: Any],
                string(chunk["type"]) == "usage",
                let parsed = chunk["usage"] as? [String: Any]
            else { return nil }
            usage = parsed
            priority = 1
        } else {
            return nil
        }

        let input = nonnegativeUInt(usage["inputTokens"])
        let rawOutput = nonnegativeUInt(usage["outputTokens"])
        let cacheRead = nonnegativeUInt(usage["cacheReadTokens"])
        let cacheWrite = nonnegativeUInt(usage["cacheWriteTokens"])
        let reasoning = min(nonnegativeUInt(usage["reasoningTokens"]), rawOutput)
        guard input + rawOutput + cacheRead + cacheWrite > 0 else { return nil }

        let normalizedModel = AIUsagePricing.normalize(
            model.isEmpty ? "deepseek-v4-pro" : model,
            provider: .deepSeek
        )
        let cost = provider.lowercased() == "deepseek-official"
            ? AIUsagePricing.estimatedCostUSD(
                provider: .deepSeek,
                model: normalizedModel,
                date: timestamp,
                inputTokens: input,
                cacheReadTokens: cacheRead,
                cacheWriteTokens: cacheWrite,
                outputTokens: rawOutput
            )
            : nil
        return DeepSeekRecord(
            turn: turn,
            step: step,
            priority: priority,
            usage: UsageEvent(
                date: timestamp,
                model: normalizedModel,
                tokens: TokenValues(
                    input: input,
                    cacheRead: cacheRead,
                    cacheWrite: cacheWrite,
                    output: rawOutput - reasoning,
                    reasoning: reasoning
                ),
                cacheWrite1h: 0,
                costUSD: cost,
                reasoningCountsSeparately: true
            )
        )
    }

    private func deepSeekFiles() -> [URL] {
        let root: URL
        if let configured = ProcessInfo.processInfo.environment["TOKEI_DSH_DIR"],
            let url = qwenAbsoluteURL(configured)
        {
            root = url
        } else {
            root = homeDirectory.appending(path: ".dsh/sessions")
        }
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            guard name.hasSuffix(".jsonl.zstd") || name.hasSuffix(".jsonl"),
                (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else { continue }
            files.append(url)
        }
        return files.sorted { $0.path < $1.path }
    }

    private func deepSeekLogData(_ url: URL) -> Data? {
        guard let source = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return url.lastPathComponent.hasSuffix(".zstd")
            ? MoniZstdDecompressFrames(source)
            : source
    }

    private func scanOpenCode(start: Date, end: Date, daily: inout [Date: DailyBucket]) -> Totals {
        var records: [String: OpenCodeRecord] = [:]
        if let databaseURL = openCodeDatabaseURL() {
            for record in openCodeDatabaseRecords(databaseURL) {
                records[record.id] = record
            }
        }

        let databaseIDs = Set(records.keys)
        for url in openCodeLegacyMessageFiles() {
            let fileID = url.deletingPathExtension().lastPathComponent
            if databaseIDs.contains(fileID) { continue }
            guard let data = try? Data(contentsOf: url),
                let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let record = openCodeRecord(
                    message,
                    fallbackID: fileID,
                    fallbackSessionID: url.deletingLastPathComponent().lastPathComponent,
                    fallbackCreatedMilliseconds: 0
                ),
                !databaseIDs.contains(record.id),
                records[record.id] == nil
            else { continue }
            records[record.id] = record
        }

        var totals = Totals()
        var sessions: Set<String> = []
        for record in records.values where record.usage.date >= start && record.usage.date < end {
            totals.add(record.usage)
            addDaily(record.usage, provider: "OpenCode", to: &daily)
            sessions.insert(record.sessionID)
        }
        totals.sessions = sessions.count
        return totals
    }

    private func openCodeDatabaseURL() -> URL? {
        let root = openCodeDataRoot()
        let primary = root.appending(path: "opencode.db")
        if fileManager.fileExists(atPath: primary.path) { return primary }
        guard let files = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        return files.filter {
            $0.pathExtension == "db" && $0.lastPathComponent.hasPrefix("opencode-")
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }.first
    }

    private func openCodeDataRoot() -> URL {
        for key in ["TOKEI_OPENCODE_DATA_DIR", "OPENCODE_DATA_DIR"] {
            if let value = ProcessInfo.processInfo.environment[key], let url = qwenAbsoluteURL(value) {
                return url
            }
        }
        return homeDirectory.appending(path: ".local/share/opencode")
    }

    private func openCodeLegacyMessageFiles() -> [URL] {
        let root: URL
        if let configured = ProcessInfo.processInfo.environment["TOKEI_OPENCODE_DIR"],
            let url = qwenAbsoluteURL(configured)
        {
            root = url
        } else {
            root = openCodeDataRoot().appending(path: "storage/message")
        }
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator
        where url.pathExtension == "json" && url.lastPathComponent.hasPrefix("msg_") {
            files.append(url)
        }
        return files.sorted { $0.path < $1.path }
    }

    private func openCodeDatabaseRecords(_ url: URL) -> [OpenCodeRecord] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
            let database
        else {
            if let database { sqlite3_close_v2(database) }
            return []
        }
        defer { sqlite3_close_v2(database) }
        sqlite3_busy_timeout(database, 1_000)

        var statement: OpaquePointer?
        let query = "SELECT id, session_id, time_created, data FROM message"
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { return [] }
        defer { sqlite3_finalize(statement) }

        var records: [OpenCodeRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let rawData = sqliteText(statement, column: 3),
                let data = rawData.data(using: .utf8),
                let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let record = openCodeRecord(
                    message,
                    fallbackID: sqliteText(statement, column: 0) ?? "",
                    fallbackSessionID: sqliteText(statement, column: 1) ?? "",
                    fallbackCreatedMilliseconds: sqlite3_column_int64(statement, 2)
                )
            else { continue }
            records.append(record)
        }
        return records
    }

    private func sqliteText(_ statement: OpaquePointer, column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
            let text = sqlite3_column_text(statement, column)
        else { return nil }
        return String(cString: text)
    }

    private func openCodeRecord(
        _ message: [String: Any],
        fallbackID: String,
        fallbackSessionID: String,
        fallbackCreatedMilliseconds: Int64
    ) -> OpenCodeRecord? {
        guard string(message["role"]) == "assistant" else { return nil }
        let time = message["time"] as? [String: Any]
        let createdMilliseconds = Int64(uint(time?["created"])) > 0
            ? Int64(uint(time?["created"]))
            : fallbackCreatedMilliseconds
        guard createdMilliseconds > 0 else { return nil }

        let id = string(message["id"]) ?? fallbackID
        let sessionID = string(message["sessionID"]) ?? fallbackSessionID
        guard !id.isEmpty, !sessionID.isEmpty else { return nil }
        let tokens = message["tokens"] as? [String: Any] ?? [:]
        let cache = tokens["cache"] as? [String: Any] ?? [:]
        let input = uint(tokens["input"])
        let output = uint(tokens["output"])
        let reasoning = uint(tokens["reasoning"])
        let cacheRead = uint(cache["read"])
        let cacheWrite = uint(cache["write"])
        guard input + output + reasoning + cacheRead + cacheWrite > 0 else { return nil }

        let date = Date(timeIntervalSince1970: Double(createdMilliseconds) / 1_000)
        let model = string(message["modelID"]) ?? "unknown"
        let recordedCost = (message["cost"] as? NSNumber)?.doubleValue
        let cost = recordedCost.flatMap { $0 > 0 && $0.isFinite ? $0 : nil }
            ?? openCodeEstimatedCost(
                model: model,
                date: date,
                input: input,
                output: output,
                reasoning: reasoning,
                cacheRead: cacheRead,
                cacheWrite: cacheWrite
            )
        return OpenCodeRecord(
            id: id,
            sessionID: sessionID,
            usage: UsageEvent(
                date: date,
                model: model,
                tokens: TokenValues(
                    input: input,
                    cacheRead: cacheRead,
                    cacheWrite: cacheWrite,
                    output: output,
                    reasoning: reasoning
                ),
                cacheWrite1h: 0,
                costUSD: cost,
                reasoningCountsSeparately: true
            )
        )
    }

    private func openCodeEstimatedCost(
        model: String,
        date: Date,
        input: UInt64,
        output: UInt64,
        reasoning: UInt64,
        cacheRead: UInt64,
        cacheWrite: UInt64
    ) -> Double? {
        let normalized = model.lowercased()
        let provider: AIUsageProvider?
        if normalized.contains("claude") || normalized.hasPrefix("anthropic/") {
            provider = .claude
        } else if normalized.hasPrefix("gpt-") || normalized.hasPrefix("openai/") {
            provider = .codex
        } else if normalized.contains("qwen") {
            provider = .qwen
        } else if normalized.contains("gemini") || normalized.hasPrefix("google/") {
            provider = .gemini
        } else {
            provider = nil
        }
        guard let provider else { return nil }
        return AIUsagePricing.estimatedCostUSD(
            provider: provider,
            model: model,
            date: date,
            inputTokens: input,
            cacheReadTokens: cacheRead,
            cacheWriteTokens: cacheWrite,
            outputTokens: output + reasoning
        )
    }

    private func scanKimi(start: Date, end: Date, daily: inout [Date: DailyBucket]) -> Totals {
        var totals = Totals()
        var sessions: Set<String> = []
        for (sessionDirectory, group) in kimiWireGroups() {
            let agentRecords = group.agentWires.flatMap(kimiRecords)
            var mirrorCounts: [String: Int] = [:]
            for record in agentRecords { mirrorCounts[record.key, default: 0] += 1 }

            var records = agentRecords
            if let rootWire = group.rootWire {
                for record in kimiRecords(rootWire) {
                    if let count = mirrorCounts[record.key], count > 0 {
                        mirrorCounts[record.key] = count - 1
                    } else {
                        records.append(record)
                    }
                }
            }

            var countedSession = false
            for record in records where record.usage.date >= start && record.usage.date < end {
                totals.add(record.usage)
                addDaily(record.usage, provider: "Kimi Code", to: &daily)
                countedSession = true
            }
            if countedSession { sessions.insert(kimiSessionID(sessionDirectory)) }
        }
        totals.sessions = sessions.count
        return totals
    }

    private func kimiWireGroups() -> [URL: KimiWireGroup] {
        var groups: [URL: KimiWireGroup] = [:]
        for root in kimiRoots() {
            let sessionsRoot = root.appending(path: "sessions")
            guard let enumerator = fileManager.enumerator(
                at: sessionsRoot,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in enumerator where url.lastPathComponent == "wire.jsonl" {
                let parent = url.deletingLastPathComponent()
                let sessionDirectory: URL
                if parent.deletingLastPathComponent().lastPathComponent == "agents" {
                    sessionDirectory = parent.deletingLastPathComponent().deletingLastPathComponent()
                    groups[sessionDirectory, default: KimiWireGroup()].agentWires.append(url)
                } else {
                    sessionDirectory = parent
                    groups[sessionDirectory, default: KimiWireGroup()].rootWire = url
                }
            }
        }
        for key in groups.keys {
            groups[key]?.agentWires.sort { $0.path < $1.path }
        }
        return groups
    }

    private func kimiRoots() -> [URL] {
        for key in ["TOKEI_KIMI_DIR", "KIMI_CODE_HOME", "KIMI_SHARE_DIR"] {
            if let value = ProcessInfo.processInfo.environment[key], let url = qwenAbsoluteURL(value) {
                return [url]
            }
        }
        return [homeDirectory.appending(path: ".kimi-code"), homeDirectory.appending(path: ".kimi")]
    }

    private func kimiSessionID(_ directory: URL) -> String {
        let stateURL = directory.appending(path: "state.json")
        if let data = try? Data(contentsOf: stateURL),
            let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let id = string(state["id"]), !id.isEmpty
        {
            return id
        }
        return directory.lastPathComponent
    }

    private func kimiRecords(_ url: URL) -> [KimiRecord] {
        var records: [KimiRecord] = []
        var seenMessages: Set<String> = []
        enumerateLines(in: url) { line in
            guard let record = json(line) else { return }
            if string(record["type"]) == "usage.record" {
                guard let timestamp = flexibleDate(record["time"]),
                    let values = record["usage"] as? [String: Any]
                else { return }
                let input = uint(values["inputOther"])
                let output = uint(values["output"])
                let cacheRead = uint(values["inputCacheRead"])
                let cacheWrite = uint(values["inputCacheCreation"])
                guard input + output + cacheRead + cacheWrite > 0 else { return }
                let model = string(record["model"])?.trimmingCharacters(in: .whitespacesAndNewlines)
                let displayModel = model.flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
                let key = [
                    "usage", String(Int64(timestamp.timeIntervalSince1970 * 1_000)), displayModel,
                    String(input), String(output), String(cacheRead), String(cacheWrite),
                ].joined(separator: ":")
                records.append(
                    KimiRecord(
                        key: key,
                        usage: kimiUsage(
                            date: timestamp,
                            model: displayModel,
                            input: input,
                            output: output,
                            cacheRead: cacheRead,
                            cacheWrite: cacheWrite
                        )
                    ))
                return
            }

            guard let timestamp = flexibleDate(record["timestamp"]),
                let message = record["message"] as? [String: Any]
            else { return }
            for (scope, payload) in kimiStatusPayloads(message) {
                guard let values = payload["token_usage"] as? [String: Any] else { continue }
                let messageID = string(payload["message_id"])
                if let messageID {
                    let deduplicationKey = "\(scope):\(messageID)"
                    guard seenMessages.insert(deduplicationKey).inserted else { continue }
                }
                let input = uint(values["input_other"])
                let output = uint(values["output"])
                let cacheRead = uint(values["input_cache_read"])
                let cacheWrite = uint(values["input_cache_creation"])
                guard input + output + cacheRead + cacheWrite > 0 else { continue }
                let key = messageID.map { "message:\(scope):\($0)" }
                    ?? [
                        "tokens", String(Int64(timestamp.timeIntervalSince1970 * 1_000)), scope,
                        String(input), String(output), String(cacheRead), String(cacheWrite),
                    ].joined(separator: ":")
                records.append(
                    KimiRecord(
                        key: key,
                        usage: kimiUsage(
                            date: timestamp,
                            model: "unknown",
                            input: input,
                            output: output,
                            cacheRead: cacheRead,
                            cacheWrite: cacheWrite
                        )
                    ))
            }
        }
        return records
    }

    private func kimiStatusPayloads(
        _ message: [String: Any],
        scope: String = "main"
    ) -> [(String, [String: Any])] {
        guard let type = string(message["type"]),
            let payload = message["payload"] as? [String: Any]
        else { return [] }
        if type == "StatusUpdate" { return [(scope, payload)] }
        guard type == "SubagentEvent", let event = payload["event"] as? [String: Any] else { return [] }
        let agent = string(payload["agent_id"])
            ?? string(payload["parent_tool_call_id"])
            ?? string(payload["task_tool_call_id"])
        return kimiStatusPayloads(event, scope: agent.map { "\(scope)/\($0)" } ?? scope)
    }

    private func kimiUsage(
        date: Date,
        model: String,
        input: UInt64,
        output: UInt64,
        cacheRead: UInt64,
        cacheWrite: UInt64
    ) -> UsageEvent {
        UsageEvent(
            date: date,
            model: model,
            tokens: TokenValues(
                input: input,
                cacheRead: cacheRead,
                cacheWrite: cacheWrite,
                output: output
            ),
            cacheWrite1h: 0,
            costUSD: nil
        )
    }

    private func scanGemini(start: Date, end: Date, daily: inout [Date: DailyBucket]) -> Totals {
        let files = geminiSessionFiles()
        let paths = Set(files.map(\.path))
        geminiCache = geminiCache.filter { paths.contains($0.key) }
        var canonical: [String: GeminiSession] = [:]
        for url in files {
            guard let signature = geminiFileSignature(url) else { continue }
            let session: GeminiSession?
            if let cached = geminiCache[url.path], cached.signature == signature {
                session = cached.session
            } else {
                session = geminiSession(url)
                geminiCache[url.path] = GeminiCacheEntry(signature: signature, session: session)
            }
            guard let session else { continue }
            if let current = canonical[session.id], !geminiSession(session, outranks: current) {
                continue
            }
            canonical[session.id] = session
        }

        var totals = Totals()
        for session in canonical.values {
            var countedSession = false
            for event in session.events where event.date >= start && event.date < end {
                totals.add(event)
                addDaily(event, provider: "Gemini CLI", to: &daily)
                countedSession = true
            }
            if countedSession { totals.sessions += 1 }
        }
        return totals
    }

    private func geminiSession(_ candidate: GeminiSession, outranks current: GeminiSession) -> Bool {
        if candidate.rank != current.rank { return candidate.rank > current.rank }
        if candidate.updatedAt != current.updatedAt { return candidate.updatedAt > current.updatedAt }
        return candidate.modifiedAt > current.modifiedAt
    }

    private func geminiSession(_ url: URL) -> GeminiSession? {
        if url.pathExtension == "db" { return antigravitySession(url) }
        guard let modifiedAt = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
        else { return nil }

        var metadata: [String: Any] = [:]
        var messages: [String: [String: Any]] = [:]
        var order: [String] = []
        let rank = url.pathExtension == "jsonl" ? 2 : 1

        if rank == 1 {
            guard let data = try? Data(contentsOf: url), let record = json(data) else { return nil }
            metadata = record
            geminiApplyMessages(record["messages"], to: &messages, order: &order)
        } else {
            enumerateLines(in: url) { line in
                guard let record = json(line) else { return }
                if let rewindID = string(record["$rewindTo"]) {
                    if let index = order.firstIndex(of: rewindID) {
                        for id in order[index...] { messages.removeValue(forKey: id) }
                        order.removeSubrange(index...)
                    } else {
                        messages.removeAll()
                        order.removeAll()
                    }
                    return
                }
                if let id = string(record["id"]), !id.isEmpty {
                    geminiApplyMessage(record, id: id, to: &messages, order: &order)
                    return
                }
                if let updates = record["$set"] as? [String: Any] {
                    if updates["messages"] is [Any] {
                        messages.removeAll()
                        order.removeAll()
                        geminiApplyMessages(updates["messages"], to: &messages, order: &order)
                    }
                    metadata.merge(updates) { _, replacement in replacement }
                    return
                }
                if let pushed = record["$push"] as? [String: Any] {
                    geminiApplyMessages(pushed["messages"], to: &messages, order: &order)
                    return
                }
                if let sessionID = string(record["sessionId"]), !sessionID.isEmpty {
                    metadata.merge(record) { _, replacement in replacement }
                    geminiApplyMessages(record["messages"], to: &messages, order: &order)
                }
            }
        }

        let events = order.compactMap { id in
            messages[id].flatMap(geminiUsageEvent)
        }
        let sessionID = string(metadata["sessionId"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        return GeminiSession(
            id: sessionID.flatMap { $0.isEmpty ? nil : $0 }
                ?? url.deletingPathExtension().lastPathComponent,
            rank: rank,
            updatedAt: flexibleDate(metadata["lastUpdated"])
                ?? events.map(\.date).max()
                ?? .distantPast,
            modifiedAt: modifiedAt,
            events: events
        )
    }

    private func geminiApplyMessages(
        _ value: Any?,
        to messages: inout [String: [String: Any]],
        order: inout [String]
    ) {
        let values: [[String: Any]]
        if let message = value as? [String: Any] {
            values = [message]
        } else {
            values = value as? [[String: Any]] ?? []
        }
        for message in values {
            guard let id = string(message["id"]), !id.isEmpty else { continue }
            geminiApplyMessage(message, id: id, to: &messages, order: &order)
        }
    }

    private func geminiApplyMessage(
        _ message: [String: Any],
        id: String,
        to messages: inout [String: [String: Any]],
        order: inout [String]
    ) {
        if messages[id] == nil { order.append(id) }
        messages[id] = message
    }

    private func geminiUsageEvent(_ message: [String: Any]) -> UsageEvent? {
        guard string(message["type"]) == "gemini",
            let timestamp = flexibleDate(message["timestamp"]),
            let values = message["tokens"] as? [String: Any]
        else { return nil }
        let inputTotal = uint(values["input"])
        let cacheRead = min(inputTotal, uint(values["cached"]))
        let input = inputTotal - cacheRead
        let output = uint(values["output"])
        let reasoning = uint(values["thoughts"])
        guard input + cacheRead + output + reasoning > 0 else { return nil }
        return geminiUsage(
            date: timestamp,
            rawModel: string(message["model"]) ?? "unknown",
            input: input,
            cacheRead: cacheRead,
            output: output,
            reasoning: reasoning
        )
    }

    private func geminiUsage(
        date: Date,
        rawModel: String,
        input: UInt64,
        cacheRead: UInt64,
        output: UInt64,
        reasoning: UInt64
    ) -> UsageEvent {
        let model = AIUsagePricing.normalize(rawModel, provider: .gemini)
        return UsageEvent(
            date: date,
            model: model,
            tokens: TokenValues(
                input: input,
                cacheRead: cacheRead,
                output: output,
                reasoning: reasoning
            ),
            cacheWrite1h: 0,
            costUSD: AIUsagePricing.estimatedCostUSD(
                provider: .gemini,
                model: model,
                date: date,
                inputTokens: input,
                cacheReadTokens: cacheRead,
                cacheWriteTokens: 0,
                outputTokens: output + reasoning
            ),
            reasoningCountsSeparately: true
        )
    }

    private func antigravitySession(_ url: URL) -> GeminiSession? {
        guard let modifiedAt = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
        else { return nil }

        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
            let database
        else {
            if let database { sqlite3_close_v2(database) }
            return nil
        }
        defer { sqlite3_close_v2(database) }
        sqlite3_busy_timeout(database, 1_000)

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT idx, data FROM gen_metadata ORDER BY idx ASC",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else { return nil }
        defer { sqlite3_finalize(statement) }

        var events: [UsageEvent] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let byteCount = Int(sqlite3_column_bytes(statement, 1))
            guard byteCount > 0, let blob = sqlite3_column_blob(statement, 1) else { continue }
            let payload = Data(bytes: blob, count: byteCount)
            for field in protobufFields(payload)
            where field.number == 1 && field.wireType == 2 {
                guard let data = field.data, let step = antigravityGeneration(data) else { continue }
                events.append(step)
            }
        }
        guard !events.isEmpty else { return nil }
        return GeminiSession(
            id: url.deletingPathExtension().lastPathComponent,
            rank: 3,
            updatedAt: events.map(\.date).max() ?? .distantPast,
            modifiedAt: modifiedAt,
            events: events
        )
    }

    private func antigravityGeneration(_ data: Data) -> UsageEvent? {
        var model = "unknown"
        var input: UInt64 = 0
        var output: UInt64 = 0
        var cacheRead: UInt64 = 0
        var reasoning: UInt64 = 0
        var timestamp: UInt64?

        for field in protobufFields(data) {
            if field.number == 19, field.wireType == 2, let bytes = field.data,
                let decoded = String(data: bytes, encoding: .utf8), geminiModelIsValid(decoded)
            {
                model = decoded
            } else if field.number == 4, field.wireType == 2, let bytes = field.data {
                for tokenField in protobufFields(bytes) where tokenField.wireType == 0 {
                    switch tokenField.number {
                    case 2: input = tokenField.varint ?? 0
                    case 3: output = tokenField.varint ?? 0
                    case 5: cacheRead = tokenField.varint ?? 0
                    case 9: reasoning = tokenField.varint ?? 0
                    default: break
                    }
                }
            } else if field.number == 9, field.wireType == 2, let bytes = field.data {
                for timeField in protobufFields(bytes)
                where timeField.number == 4 && timeField.wireType == 2 {
                    guard let nested = timeField.data else { continue }
                    timestamp = protobufFields(nested).first {
                        $0.number == 1 && $0.wireType == 0
                    }?.varint
                }
            }
        }

        let maximum: UInt64 = 100_000_000
        guard let timestamp,
            timestamp >= 1_577_836_800,
            timestamp <= 1 << 34,
            max(input, output, cacheRead, reasoning) <= maximum,
            input + output + cacheRead + reasoning > 0
        else { return nil }
        return geminiUsage(
            date: Date(timeIntervalSince1970: Double(timestamp)),
            rawModel: model,
            input: input,
            cacheRead: cacheRead,
            output: output,
            reasoning: reasoning
        )
    }

    private func geminiModelIsValid(_ model: String) -> Bool {
        !model.isEmpty && model.count <= 120 && model.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0)
        }
    }

    private func protobufFields(_ data: Data) -> [ProtobufField] {
        let bytes = [UInt8](data)
        var offset = 0
        var fields: [ProtobufField] = []
        while offset < bytes.count {
            guard let key = protobufVarint(bytes, offset: &offset) else { break }
            let number = Int(key >> 3)
            let wireType = Int(key & 0x7)
            guard number > 0 else { break }
            switch wireType {
            case 0:
                guard let value = protobufVarint(bytes, offset: &offset) else { return fields }
                fields.append(ProtobufField(number: number, wireType: wireType, varint: value, data: nil))
            case 2:
                guard let rawLength = protobufVarint(bytes, offset: &offset),
                    rawLength <= UInt64(bytes.count - offset)
                else { return fields }
                let length = Int(rawLength)
                let end = offset + length
                fields.append(
                    ProtobufField(
                        number: number,
                        wireType: wireType,
                        varint: nil,
                        data: Data(bytes[offset..<end])
                    ))
                offset = end
            case 1, 5:
                let width = wireType == 1 ? 8 : 4
                guard offset + width <= bytes.count else { return fields }
                let end = offset + width
                fields.append(
                    ProtobufField(
                        number: number,
                        wireType: wireType,
                        varint: nil,
                        data: Data(bytes[offset..<end])
                    ))
                offset = end
            default:
                return fields
            }
        }
        return fields
    }

    private func protobufVarint(_ bytes: [UInt8], offset: inout Int) -> UInt64? {
        var value: UInt64 = 0
        var shift = 0
        for _ in 0..<10 {
            guard offset < bytes.count else { return nil }
            let byte = bytes[offset]
            offset += 1
            let payload = UInt64(byte & 0x7f)
            if shift == 63, payload > 1 { return nil }
            value |= payload << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
        return nil
    }

    private func geminiSessionFiles() -> [URL] {
        var files: [URL] = []
        var seen: Set<String> = []
        for root in geminiRoots() {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in enumerator {
                let name = url.lastPathComponent
                let isDatabase = url.pathExtension == "db" && name != "conversation_summaries.db"
                let isSessionJSON = url.pathExtension == "json" && name.hasPrefix("session-")
                let isSessionJSONL = url.pathExtension == "jsonl"
                    && (name.hasPrefix("session-") || url.path.contains("/chats/"))
                guard isDatabase || isSessionJSON || isSessionJSONL,
                    (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                else { continue }
                let standardized = url.standardizedFileURL
                if seen.insert(standardized.path).inserted { files.append(standardized) }
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    private func geminiFileSignature(_ url: URL) -> GeminiFileSignature? {
        guard let database = fileSignature(url) else { return nil }
        let writeAheadLog = url.pathExtension == "db"
            ? fileSignature(URL(fileURLWithPath: url.path + "-wal"))
            : nil
        return GeminiFileSignature(database: database, writeAheadLog: writeAheadLog)
    }

    private func geminiRoots() -> [URL] {
        var roots = environmentPaths("TOKEI_GEMINI_DIR")
        roots.append(contentsOf: [
            homeDirectory.appending(path: ".gemini/tmp"),
            homeDirectory.appending(path: ".gemini/antigravity-cli/conversations"),
            homeDirectory.appending(path: ".gemini/antigravity/conversations"),
            homeDirectory.appending(path: ".gemini/antigravity-ide/conversations"),
            homeDirectory.appending(path: ".gemini/gemini-cli/conversations"),
        ])
        roots.append(contentsOf: environmentPaths("TOKEI_ANTIGRAVITY_DIR"))
        var seen: Set<String> = []
        return roots.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private func environmentPaths(_ key: String) -> [URL] {
        guard let value = ProcessInfo.processInfo.environment[key] else { return [] }
        return value.split(separator: ":").compactMap { qwenAbsoluteURL(String($0)) }
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
            let cacheCreation = usage["cache_creation"] as? [String: Any]
            let cacheWrite1h = uint(cacheCreation?["ephemeral_1h_input_tokens"])
            let cacheWrite5m = cacheCreation?["ephemeral_5m_input_tokens"] == nil
                && cacheCreation?["ephemeral_1h_input_tokens"] == nil
                ? nil
                : uint(cacheCreation?["ephemeral_5m_input_tokens"])
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
                        cacheWrite5mTokens: cacheWrite5m,
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
        claudeCacheDirty = true
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
        let candidateTokens = eventTotal(candidate.usage)
        let currentTokens = eventTotal(current.usage)
        if candidateTokens != currentTokens {
            return candidateTokens > currentTokens ? candidate : current
        }
        return (candidate.usage.costUSD ?? 0) > (current.usage.costUSD ?? 0) ? candidate : current
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

    private func addDaily(
        _ event: UsageEvent,
        provider: String,
        to daily: inout [Date: DailyBucket]
    ) {
        daily[calendar.startOfDay(for: event.date), default: DailyBucket()].add(
            event,
            provider: provider
        )
    }

    private func eventTotal(_ event: UsageEvent) -> UInt64 {
        event.tokens.input + event.tokens.cacheRead + event.tokens.cacheWrite + event.tokens.output
            + (event.reasoningCountsSeparately ? event.tokens.reasoning : 0)
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
        let plan = AIQuotaFetcher.codexPlan(string(rateLimits["plan_type"]))
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

    private func enumerateCompleteLines(
        in url: URL,
        from offset: UInt64,
        body: (Data) -> Void
    ) -> UInt64 {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
            offset <= UInt64(data.count)
        else { return offset }

        var lineStart = data.index(data.startIndex, offsetBy: Int(offset))
        var completeOffset = offset
        while lineStart < data.endIndex,
            let newline = data[lineStart...].firstIndex(of: 0x0A)
        {
            autoreleasepool { body(Data(data[lineStart..<newline])) }
            let next = data.index(after: newline)
            completeOffset = UInt64(data.distance(from: data.startIndex, to: next))
            lineStart = next
        }
        return completeOffset
    }

    private func enumerateLines(in url: URL, body: (Data) -> Void) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return }
        enumerateLines(in: data, body: body)
    }

    private func persistCodexCacheIfNeeded() {
        guard codexCacheDirty else { return }
        Self.persistCache(codexCache, to: Self.codexCacheURL(homeDirectory: homeDirectory))
        codexCacheDirty = false
    }

    private func loadPersistentCachesIfNeeded() {
        guard !loadedPersistentCaches else { return }
        codexCache = Self.loadCache(
            [String: CodexCacheEntry].self,
            from: Self.codexCacheURL(homeDirectory: homeDirectory)
        ) ?? [:]
        claudeCache = Self.loadCache(
            [String: ClaudeCacheEntry].self,
            from: Self.claudeCacheURL(homeDirectory: homeDirectory)
        ) ?? [:]
        loadedPersistentCaches = true
    }

    private func persistClaudeCacheIfNeeded() {
        guard claudeCacheDirty else { return }
        Self.persistCache(claudeCache, to: Self.claudeCacheURL(homeDirectory: homeDirectory))
        claudeCacheDirty = false
    }

    private static func loadCache<Value: Decodable>(_ type: Value.Type, from url: URL) -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? PropertyListDecoder().decode(type, from: data)
    }

    private static func persistCache<Value: Encodable>(_ value: Value, to url: URL) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            try encoder.encode(value).write(to: url, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        } catch {
            return
        }
    }

    private static func codexCacheURL(homeDirectory: URL) -> URL {
        cacheDirectory(homeDirectory: homeDirectory)
            .appending(path: "codex-index-v1.plist")
    }

    private static func claudeCacheURL(homeDirectory: URL) -> URL {
        cacheDirectory(homeDirectory: homeDirectory)
            .appending(path: "claude-index-v1.plist")
    }

    private static func cacheDirectory(homeDirectory: URL) -> URL {
        homeDirectory.appending(
            path: "Library/Application Support/Moni/AIUsageCache",
            directoryHint: .isDirectory
        )
    }

    private func enumerateLines(in data: Data, body: (Data) -> Void) {
        var lineStart = data.startIndex
        while lineStart < data.endIndex,
            let newline = data[lineStart...].firstIndex(of: 0x0A)
        {
            autoreleasepool { body(Data(data[lineStart..<newline])) }
            lineStart = data.index(after: newline)
        }
        if lineStart < data.endIndex {
            autoreleasepool { body(Data(data[lineStart...])) }
        }
    }

    private func json(_ line: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
    }

    private func date(_ value: Any?) -> Date? {
        guard let string = string(value) else { return nil }
        return formatter.date(from: string) ?? fallbackFormatter.date(from: string)
    }

    private func flexibleDate(_ value: Any?) -> Date? {
        if let number = value as? NSNumber {
            let raw = number.doubleValue
            guard raw.isFinite, raw > 0 else { return nil }
            return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1_000 : raw)
        }
        return date(value)
    }

    private func localDayDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
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

    private func nonnegativeUInt(_ value: Any?) -> UInt64 {
        guard let number = value as? NSNumber else { return 0 }
        let raw = number.int64Value
        guard raw >= 0, number.doubleValue == Double(raw) else { return 0 }
        return UInt64(raw)
    }

    private func nonnegativeInt(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        let raw = number.doubleValue
        guard raw.isFinite, raw >= 0, raw.rounded(.towardZero) == raw,
            raw <= Double(Int.max)
        else { return nil }
        return Int(raw)
    }
}
