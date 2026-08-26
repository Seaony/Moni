import Combine
import Foundation

@MainActor
final class AIUsageStore: ObservableObject {
    private static let quotaRefreshInterval: TimeInterval = 5 * 60
    private static let retainedUntimedQuotaInterval: TimeInterval = 30 * 60

    private enum Query: Equatable {
        case days(Int)
        case range(AIUsageRange)

        var cacheKey: String {
            switch self {
            case .days(let days): "days:\(days)"
            case .range(let range): "range:\(range.rawValue)"
            }
        }
    }

    private struct CachedSummary: Codable {
        let summary: AIUsageSummary
        let storedAt: Date
    }

    @Published private(set) var summary = AIUsageSummary()
    @Published private(set) var isLoading = false

    private let scanner = AIUsageScanner()
    private var cachedSummaries: [String: CachedSummary]
    private var displayedQuery: Query?
    private var completedQuery: Query?
    private var activeRequest: (query: Query, includeQuotas: Bool, allowClaudeKeychainPrompt: Bool)?
    private var pendingRequest: (query: Query, includeQuotas: Bool, allowClaudeKeychainPrompt: Bool)?
    private var attemptedAutomaticClaudeKeychainPrompt = false

    init() {
        let cachedSummaries = Self.loadCachedSummaries()
        self.cachedSummaries = cachedSummaries

        let storedDays = UserDefaults.standard.integer(forKey: PreferenceKey.aiUsageRangeDays)
        let query = Query.days(storedDays == 0 ? 30 : storedDays)
        if let cached = cachedSummaries[query.cacheKey] {
            summary = cached.summary
            displayedQuery = query
            let widgetSnapshot = WidgetAISnapshot(summary: cached.summary)
            Task {
                await WidgetSnapshotWriter.shared.persistAI(widgetSnapshot)
            }
        }
    }

    func loadIfNeeded(
        days: Int? = nil,
        includeQuotas: Bool = false,
        allowClaudeKeychainPrompt: Bool = false
    ) {
        let storedDays = UserDefaults.standard.integer(forKey: PreferenceKey.aiUsageRangeDays)
        loadIfNeeded(
            query: .days(days ?? (storedDays == 0 ? 30 : storedDays)),
            includeQuotas: includeQuotas,
            allowClaudeKeychainPrompt: allowClaudeKeychainPrompt
        )
    }

    func loadIfNeeded(
        range: AIUsageRange,
        includeQuotas: Bool = false,
        allowClaudeKeychainPrompt: Bool = false
    ) {
        loadIfNeeded(
            query: .range(range),
            includeQuotas: includeQuotas,
            allowClaudeKeychainPrompt: allowClaudeKeychainPrompt
        )
    }

    func refresh(
        days: Int? = nil,
        includeQuotas: Bool = false,
        allowClaudeKeychainPrompt: Bool = false
    ) {
        let storedDays = UserDefaults.standard.integer(forKey: PreferenceKey.aiUsageRangeDays)
        refresh(
            query: .days(days ?? (storedDays == 0 ? 30 : storedDays)),
            includeQuotas: includeQuotas,
            allowClaudeKeychainPrompt: allowClaudeKeychainPrompt
        )
    }

    func refresh(
        range: AIUsageRange,
        includeQuotas: Bool = false,
        allowClaudeKeychainPrompt: Bool = false
    ) {
        refresh(
            query: .range(range),
            includeQuotas: includeQuotas,
            allowClaudeKeychainPrompt: allowClaudeKeychainPrompt
        )
    }

    func refreshCurrent(
        includeQuotas: Bool = false,
        allowClaudeKeychainPrompt: Bool = false
    ) {
        let stored = UserDefaults.standard.string(forKey: PreferenceKey.aiUsageRange)
        refresh(
            range: AIUsageRange(rawValue: stored ?? "") ?? .month,
            includeQuotas: includeQuotas,
            allowClaudeKeychainPrompt: allowClaudeKeychainPrompt
        )
    }

    private func loadIfNeeded(
        query: Query,
        includeQuotas: Bool,
        allowClaudeKeychainPrompt: Bool = false
    ) {
        presentCachedSummary(for: query)
        let shouldPrompt = allowClaudeKeychainPrompt && !attemptedAutomaticClaudeKeychainPrompt
        if shouldPrompt { attemptedAutomaticClaudeKeychainPrompt = true }
        let refreshQuotas = includeQuotas && (quotaRefreshIsDue(for: query) || shouldPrompt)
        guard completedQuery != query || refreshQuotas else { return }
        refresh(
            query: query,
            includeQuotas: refreshQuotas,
            allowClaudeKeychainPrompt: shouldPrompt
        )
    }

    private func refresh(
        query: Query,
        includeQuotas: Bool,
        allowClaudeKeychainPrompt: Bool
    ) {
        guard !isLoading else {
            let request = (
                query: query,
                includeQuotas: includeQuotas,
                allowClaudeKeychainPrompt: allowClaudeKeychainPrompt
            )
            if activeRequest?.query != request.query
                || (request.includeQuotas && activeRequest?.includeQuotas == false)
                || (request.allowClaudeKeychainPrompt && activeRequest?.allowClaudeKeychainPrompt == false)
            {
                pendingRequest = request
            }
            return
        }

        activeRequest = (query, includeQuotas, allowClaudeKeychainPrompt)
        isLoading = true
        Task {
            let scanned: AIUsageSummary
            switch query {
            case .days(let days):
                scanned = await scanner.scan(days: days)
            case .range(let range):
                scanned = await scanner.scan(range: range)
            }
            let localSummary = preservingValidQuotaData(
                in: scanned,
                from: cachedSummaries[query.cacheKey]?.summary
            )
            publish(localSummary, for: query)

            if includeQuotas {
                let refreshed = await scanner.refreshQuotas(
                    in: localSummary,
                    allowClaudeKeychainPrompt: allowClaudeKeychainPrompt
                )
                publish(preservingValidQuotaData(in: refreshed, from: localSummary), for: query)
            }

            activeRequest = nil
            isLoading = false
            if let pendingRequest {
                self.pendingRequest = nil
                refresh(
                    query: pendingRequest.query,
                    includeQuotas: pendingRequest.includeQuotas,
                    allowClaudeKeychainPrompt: pendingRequest.allowClaudeKeychainPrompt
                )
            }
        }
    }

    private func publish(_ value: AIUsageSummary, for query: Query) {
        summary = value
        displayedQuery = query
        completedQuery = query
        cachedSummaries[query.cacheKey] = CachedSummary(summary: value, storedAt: Date())
        Self.persistCachedSummaries(cachedSummaries)
        let widgetSnapshot = WidgetAISnapshot(summary: value)
        Task {
            await WidgetSnapshotWriter.shared.persistAI(widgetSnapshot)
        }
    }

    private func quotaRefreshIsDue(for query: Query, now: Date = Date()) -> Bool {
        guard let cached = cachedSummaries[query.cacheKey]?.summary,
            let scannedAt = cached.quotaScannedAt
        else {
            return true
        }
        if cached.providers.flatMap(\.quotaWindows).contains(where: {
            $0.resetsAt.map { $0 <= now } ?? false
        }) {
            return true
        }
        return now.timeIntervalSince(scannedAt) >= Self.quotaRefreshInterval
    }

    private func preservingValidQuotaData(
        in current: AIUsageSummary,
        from previous: AIUsageSummary?,
        now: Date = Date()
    ) -> AIUsageSummary {
        guard let previous else { return current }
        let recentUntimedQuota = previous.quotaScannedAt.map {
            now.timeIntervalSince($0) < Self.retainedUntimedQuotaInterval
        } ?? false
        var merged = current
        merged.quotaScannedAt = current.quotaScannedAt ?? previous.quotaScannedAt
        merged.providers = current.providers.map { provider in
            guard provider.quotaWindows.isEmpty,
                let oldProvider = previous.providers.first(where: { $0.provider == provider.provider })
            else { return provider }
            let windows = oldProvider.quotaWindows.filter {
                $0.resetsAt.map { $0 > now } ?? recentUntimedQuota
            }
            guard !windows.isEmpty else { return provider }
            return AIProviderUsage(
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
                planName: oldProvider.planName ?? provider.planName,
                quotaWindows: windows,
                quotaMessage: provider.quotaMessage ?? oldProvider.quotaMessage
            )
        }
        return merged
    }

    private func presentCachedSummary(for query: Query) {
        guard displayedQuery != query else { return }
        summary = cachedSummaries[query.cacheKey]?.summary ?? AIUsageSummary()
        displayedQuery = query
    }

    private static var cacheURL: URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
        return support
            .appending(path: "Moni", directoryHint: .isDirectory)
            .appending(path: "ai-usage-summaries-v1.json")
    }

    private static func loadCachedSummaries() -> [String: CachedSummary] {
        guard let data = try? Data(contentsOf: cacheURL),
            let cache = try? JSONDecoder().decode([String: CachedSummary].self, from: data)
        else { return [:] }
        return cache
    }

    private static func persistCachedSummaries(_ cache: [String: CachedSummary]) {
        let url = cacheURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(cache)
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        } catch {
            return
        }
    }
}
