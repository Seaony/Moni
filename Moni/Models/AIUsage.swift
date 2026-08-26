import Foundation

enum AIUsageRange: String, CaseIterable, Identifiable, Sendable {
    case today
    case yesterday
    case week
    case lastWeek
    case month
    case year

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "Today"
        case .yesterday: "Yesterday"
        case .week: "This week"
        case .lastWeek: "Last week"
        case .month: "This month"
        case .year: "This year"
        }
    }

    nonisolated func interval(containing date: Date, calendar: Calendar = .current) -> DateInterval {
        let today = calendar.startOfDay(for: date)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? date

        switch self {
        case .today:
            return DateInterval(start: today, end: tomorrow)
        case .yesterday:
            let start = calendar.date(byAdding: .day, value: -1, to: today) ?? today
            return DateInterval(start: start, end: today)
        case .week:
            let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? today
            return DateInterval(start: start, end: tomorrow)
        case .lastWeek:
            let thisWeek = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? today
            let start = calendar.date(byAdding: .weekOfYear, value: -1, to: thisWeek) ?? thisWeek
            return DateInterval(start: start, end: thisWeek)
        case .month:
            let start = calendar.dateInterval(of: .month, for: date)?.start ?? today
            return DateInterval(start: start, end: tomorrow)
        case .year:
            let start = calendar.dateInterval(of: .year, for: date)?.start ?? today
            return DateInterval(start: start, end: tomorrow)
        }
    }
}

struct AIModelUsage: Identifiable, Sendable {
    let model: String
    let totalTokens: UInt64
    let inputTokens: UInt64
    let outputTokens: UInt64
    let cacheReadTokens: UInt64
    let cacheWriteTokens: UInt64
    let reasoningTokens: UInt64
    let requestCount: Int
    let estimatedCostUSD: Double?

    var id: String { model }
}

struct AIQuotaWindow: Identifiable, Sendable {
    let id: String
    let label: String
    let usedPercent: Double
    let windowMinutes: Int?
    let resetsAt: Date?

    var remainingPercent: Double {
        min(100, max(0, 100 - usedPercent))
    }
}

struct AIProviderUsage: Identifiable, Sendable {
    let provider: String
    let totalTokens: UInt64
    let inputTokens: UInt64
    let outputTokens: UInt64
    let cacheReadTokens: UInt64
    let cacheWriteTokens: UInt64
    let reasoningTokens: UInt64
    let requestCount: Int
    let sessionCount: Int
    let estimatedCostUSD: Double?
    let unpricedRequestCount: Int
    let models: [AIModelUsage]
    let lastUpdated: Date?
    let planName: String?
    let quotaWindows: [AIQuotaWindow]
    let quotaMessage: String?

    var id: String { provider }

    var cacheHitPercent: Double? {
        let allInput = inputTokens + cacheReadTokens + cacheWriteTokens
        guard allInput > 0 else { return nil }
        return Double(cacheReadTokens) / Double(allInput) * 100
    }
}

struct DailyAIUsage: Identifiable, Sendable {
    let date: Date
    let tokens: UInt64
    let costUSD: Double
    let requestCount: Int

    var id: Date { date }
}

struct AIUsageSummary: Sendable {
    var providers: [AIProviderUsage] = []
    var daily: [DailyAIUsage] = []
    var scannedAt: Date?
    var quotaScannedAt: Date?

    var totalTokens: UInt64 {
        providers.reduce(0) { $0 + $1.totalTokens }
    }

    var estimatedCostUSD: Double? {
        let costs = providers.compactMap(\.estimatedCostUSD)
        return costs.isEmpty ? nil : costs.reduce(0, +)
    }

    var requestCount: Int {
        providers.reduce(0) { $0 + $1.requestCount }
    }

    var pricedRequestCount: Int {
        providers.reduce(0) { $0 + max(0, $1.requestCount - $1.unpricedRequestCount) }
    }

    var cacheHitPercent: Double? {
        let input = providers.reduce(UInt64(0)) { $0 + $1.inputTokens }
        let cacheRead = providers.reduce(UInt64(0)) { $0 + $1.cacheReadTokens }
        let cacheWrite = providers.reduce(UInt64(0)) { $0 + $1.cacheWriteTokens }
        let total = input + cacheRead + cacheWrite
        guard total > 0 else { return nil }
        return Double(cacheRead) / Double(total) * 100
    }
}
