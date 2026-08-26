import Foundation

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
}
