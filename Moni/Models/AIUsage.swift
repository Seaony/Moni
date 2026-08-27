import Foundation

nonisolated enum AIUsageRange: String, CaseIterable, Codable, Identifiable, Sendable {
    case last30Days
    case last90Days
    case all

    var id: String { rawValue }

    var title: String {
        let key: String = switch self {
        case .last30Days: "Last 30 days"
        case .last90Days: "Last 90 days"
        case .all: "All"
        }
        return MoniLocalization.string(key)
    }

    nonisolated func interval(containing date: Date, calendar: Calendar = .current) -> DateInterval {
        let today = calendar.startOfDay(for: date)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? date

        switch self {
        case .last30Days:
            let start = calendar.date(byAdding: .day, value: -29, to: today) ?? today
            return DateInterval(start: start, end: tomorrow)
        case .last90Days:
            let start = calendar.date(byAdding: .day, value: -89, to: today) ?? today
            return DateInterval(start: start, end: tomorrow)
        case .all:
            return DateInterval(start: .distantPast, end: tomorrow)
        }
    }
}

nonisolated struct AIModelUsage: Codable, Identifiable, Sendable {
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

nonisolated struct AIQuotaWindow: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let label: String
    let usedPercent: Double
    let windowMinutes: Int?
    let resetsAt: Date?

    var remainingPercent: Double {
        min(100, max(0, 100 - usedPercent))
    }
}

nonisolated struct AIProviderUsage: Codable, Identifiable, Sendable {
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

nonisolated struct DailyAIUsage: Codable, Identifiable, Sendable {
    let date: Date
    let tokens: UInt64
    let costUSD: Double
    let requestCount: Int
    let providers: [String: DailyAIProviderUsage]?

    var id: Date { date }
}

nonisolated struct DailyAIProviderUsage: Codable, Sendable {
    let tokens: UInt64
    let costUSD: Double
}

nonisolated struct AIUsageSummary: Codable, Sendable {
    var providers: [AIProviderUsage] = []
    var daily: [DailyAIUsage] = []
    var scannedAt: Date?
    var quotaScannedAt: Date?
    var weeklyWindowCostsUSD: [String: Double]?

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
