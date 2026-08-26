import Foundation

struct AIProviderUsage: Identifiable, Sendable {
    let provider: String
    let totalTokens: UInt64
    let inputTokens: UInt64
    let outputTokens: UInt64
    let cachedTokens: UInt64
    let reasoningTokens: UInt64
    let sessionCount: Int
    let topModel: String?
    let lastUpdated: Date?

    var id: String { provider }
}

struct DailyAIUsage: Identifiable, Sendable {
    let date: Date
    let tokens: UInt64

    var id: Date { date }
}

struct AIUsageSummary: Sendable {
    var providers: [AIProviderUsage] = []
    var daily: [DailyAIUsage] = []
    var scannedAt: Date?

    var totalTokens: UInt64 {
        providers.reduce(0) { $0 + $1.totalTokens }
    }
}
