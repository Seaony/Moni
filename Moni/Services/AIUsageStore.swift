import Combine
import Foundation

@MainActor
final class AIUsageStore: ObservableObject {
    private static let quotaRefreshInterval: TimeInterval = 5 * 60
    private static let retainedUntimedQuotaInterval: TimeInterval = 30 * 60

    /// The dashboard card leads with today's tokens and a two-week trend, so it
    /// reads a rolling window. The AI screen reads a calendar period the user
    /// picks. These are genuinely different questions: folding the card onto the
    /// screen's period empties it whenever that period excludes today, and even
    /// month-to-date collapses to a single bar on the 1st.
    private enum Query: Hashable {
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
    private var completedQueries: Set<Query> = []
    private struct Request: Equatable {
        let query: Query
        let includeQuotas: Bool
        let allowKeychainPrompt: Bool
        let allowBrowserKeychainPrompt: Bool

        /// Whether `self` asks for something `other` does not already cover.
        func exceeds(_ other: Request?) -> Bool {
            guard let other else { return true }
            return query != other.query
                || (includeQuotas && !other.includeQuotas)
                || (allowKeychainPrompt && !other.allowKeychainPrompt)
                || (allowBrowserKeychainPrompt && !other.allowBrowserKeychainPrompt)
        }
    }

    private var activeRequest: Request?
    private var pendingRequest: Request?
    private var attemptedAutomaticKeychainPrompt = false

    init() {
        let cachedSummaries = Self.loadCachedSummaries()
        self.cachedSummaries = cachedSummaries

        if let cached = cachedSummaries[Self.dashboardQuery.cacheKey] {
            summary = cached.summary
            displayedQuery = Self.dashboardQuery
            let widgetSnapshot = WidgetAISnapshot(summary: cached.summary)
            Task {
                await WidgetSnapshotWriter.shared.persistAI(widgetSnapshot)
            }
        }
    }

    static let dashboardWindowDays = 30

    private static var dashboardQuery: Query { .days(dashboardWindowDays) }

    static func storedRange() -> AIUsageRange {
        AIUsageRange(rawValue: UserDefaults.standard.string(forKey: PreferenceKey.aiUsageRange) ?? "")
            ?? .month
    }

    func loadDashboardIfNeeded(
        includeQuotas: Bool = false,
        allowKeychainPrompt: Bool = false
    ) {
        loadIfNeeded(
            query: Self.dashboardQuery,
            includeQuotas: includeQuotas,
            allowKeychainPrompt: allowKeychainPrompt
        )
    }

    func loadIfNeeded(
        range: AIUsageRange,
        includeQuotas: Bool = false,
        allowKeychainPrompt: Bool = false
    ) {
        loadIfNeeded(
            query: .range(range),
            includeQuotas: includeQuotas,
            allowKeychainPrompt: allowKeychainPrompt
        )
    }

    /// ⌘R has to refresh whichever window is actually on screen, not whatever the
    /// AI screen's picker was last set to.
    func refreshCurrent(
        includeQuotas: Bool = false,
        allowKeychainPrompt: Bool = false
    ) {
        refresh(
            query: displayedQuery ?? Self.dashboardQuery,
            includeQuotas: includeQuotas,
            allowKeychainPrompt: allowKeychainPrompt,
            allowBrowserKeychainPrompt: allowKeychainPrompt
        )
    }

    func refresh(
        range: AIUsageRange,
        includeQuotas: Bool = false,
        allowKeychainPrompt: Bool = false
    ) {
        refresh(
            query: .range(range),
            includeQuotas: includeQuotas,
            allowKeychainPrompt: allowKeychainPrompt,
            allowBrowserKeychainPrompt: allowKeychainPrompt
        )
    }

    private func loadIfNeeded(
        query: Query,
        includeQuotas: Bool,
        allowKeychainPrompt: Bool
    ) {
        presentCachedSummary(for: query)
        let shouldPrompt = allowKeychainPrompt && !attemptedAutomaticKeychainPrompt
        if shouldPrompt { attemptedAutomaticKeychainPrompt = true }
        let refreshQuotas = includeQuotas && (quotaRefreshIsDue(for: query) || shouldPrompt)
        // A Set, not a single value: the dashboard and the AI screen alternate, and
        // a scalar made every switch look like a new window and rescan.
        guard !completedQueries.contains(query) || refreshQuotas else { return }
        // Browser cookie stores can each raise a Keychain dialog; an automatic
        // refresh on panel open is not the moment for that, so only explicit
        // refreshes (⌘R, Rescan now) may prompt for them.
        refresh(
            query: query,
            includeQuotas: refreshQuotas,
            allowKeychainPrompt: shouldPrompt,
            allowBrowserKeychainPrompt: false
        )
    }

    private func refresh(
        query: Query,
        includeQuotas: Bool,
        allowKeychainPrompt: Bool,
        allowBrowserKeychainPrompt: Bool
    ) {
        presentCachedSummary(for: query)
        let request = Request(
            query: query,
            includeQuotas: includeQuotas,
            allowKeychainPrompt: allowKeychainPrompt,
            allowBrowserKeychainPrompt: allowBrowserKeychainPrompt
        )
        guard !isLoading else {
            if request.exceeds(activeRequest) {
                pendingRequest = request
            }
            return
        }

        activeRequest = request
        isLoading = true
        Task {
            let scanned: AIUsageSummary
            switch query {
            case .days(let days): scanned = await scanner.scan(days: days)
            case .range(let range): scanned = await scanner.scan(range: range)
            }
            let localSummary = preservingValidQuotaData(
                in: scanned,
                from: cachedSummaries[query.cacheKey]?.summary
            )
            let localSummaryWithWeeklyCosts = includeQuotas
                ? localSummary
                : await scanner.refreshWeeklyWindowCosts(in: localSummary)
            publish(localSummaryWithWeeklyCosts, for: query)

            if includeQuotas {
                let refreshed = await scanner.refreshQuotas(
                    in: localSummaryWithWeeklyCosts,
                    allowKeychainPrompt: allowKeychainPrompt,
                    allowBrowserKeychainPrompt: allowBrowserKeychainPrompt,
                    disabledProviders: Self.disabledProviders()
                )
                publish(preservingValidQuotaData(in: refreshed, from: localSummaryWithWeeklyCosts), for: query)
            }

            activeRequest = nil
            isLoading = false
            if let pendingRequest {
                self.pendingRequest = nil
                refresh(
                    query: pendingRequest.query,
                    includeQuotas: pendingRequest.includeQuotas,
                    allowKeychainPrompt: pendingRequest.allowKeychainPrompt,
                    allowBrowserKeychainPrompt: pendingRequest.allowBrowserKeychainPrompt
                )
            }
        }
    }

    private func publish(_ value: AIUsageSummary, for query: Query) {
        completedQueries.insert(query)
        cachedSummaries[query.cacheKey] = CachedSummary(summary: value, storedAt: Date())
        Self.persistCachedSummaries(cachedSummaries)
        if displayedQuery == query {
            summary = value
        }
        // Widgets show the dashboard window; a transient picker choice on the AI
        // screen must not rewrite what they display.
        guard query == Self.dashboardQuery else { return }
        let widgetSnapshot = WidgetAISnapshot(summary: value)
        Task {
            await WidgetSnapshotWriter.shared.persistAI(widgetSnapshot)
        }
    }

    private static func disabledProviders() -> Set<String> {
        Set(
            (UserDefaults.standard.string(forKey: PreferenceKey.disabledAIProviders) ?? "")
                .split(separator: ",")
                .map(String.init)
        )
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
