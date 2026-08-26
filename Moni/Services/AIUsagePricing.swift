import Foundation

enum AIUsageProvider: Sendable {
    case codex
    case claude
    case qwen
}

enum AIUsagePricing {
    private struct Price: Sendable {
        let input: Double
        let cacheRead: Double
        let cacheWrite: Double
        let cacheWrite1h: Double
        let output: Double
        let threshold: UInt64?
        let longInput: Double?
        let longCacheRead: Double?
        let longCacheWrite: Double?
        let longOutput: Double?

        nonisolated init(
            input: Double,
            cacheRead: Double,
            cacheWrite: Double? = nil,
            cacheWrite1h: Double? = nil,
            output: Double,
            threshold: UInt64? = nil,
            longInput: Double? = nil,
            longCacheRead: Double? = nil,
            longCacheWrite: Double? = nil,
            longOutput: Double? = nil
        ) {
            self.input = input
            self.cacheRead = cacheRead
            self.cacheWrite = cacheWrite ?? input
            self.cacheWrite1h = cacheWrite1h ?? input * 2
            self.output = output
            self.threshold = threshold
            self.longInput = longInput
            self.longCacheRead = longCacheRead
            self.longCacheWrite = longCacheWrite
            self.longOutput = longOutput
        }
    }

    private nonisolated static let codexPrices: [String: Price] = [
        "gpt-5": Price(input: 1.25, cacheRead: 0.125, output: 10),
        "gpt-5-codex": Price(input: 1.25, cacheRead: 0.125, output: 10),
        "gpt-5-mini": Price(input: 0.25, cacheRead: 0.025, output: 2),
        "gpt-5-nano": Price(input: 0.05, cacheRead: 0.005, output: 0.4),
        "gpt-5-pro": Price(input: 15, cacheRead: 15, output: 120),
        "gpt-5.1": Price(input: 1.25, cacheRead: 0.125, output: 10),
        "gpt-5.1-codex": Price(input: 1.25, cacheRead: 0.125, output: 10),
        "gpt-5.1-codex-max": Price(input: 1.25, cacheRead: 0.125, output: 10),
        "gpt-5.1-codex-mini": Price(input: 0.25, cacheRead: 0.025, output: 2),
        "gpt-5.2": Price(input: 1.75, cacheRead: 0.175, output: 14),
        "gpt-5.2-codex": Price(input: 1.75, cacheRead: 0.175, output: 14),
        "gpt-5.2-pro": Price(input: 21, cacheRead: 21, output: 168),
        "gpt-5.3-codex": Price(input: 1.75, cacheRead: 0.175, output: 14),
        "gpt-5.3-codex-spark": Price(input: 0, cacheRead: 0, cacheWrite: 0, output: 0),
        "gpt-5.4": Price(
            input: 2.5,
            cacheRead: 0.25,
            output: 15,
            threshold: 272_000,
            longInput: 5,
            longCacheRead: 0.5,
            longOutput: 22.5
        ),
        "gpt-5.4-mini": Price(input: 0.75, cacheRead: 0.075, output: 4.5),
        "gpt-5.4-nano": Price(input: 0.2, cacheRead: 0.02, output: 1.25),
        "gpt-5.4-pro": Price(input: 30, cacheRead: 30, output: 180),
        "gpt-5.5": Price(
            input: 5,
            cacheRead: 0.5,
            output: 30,
            threshold: 272_000,
            longInput: 10,
            longCacheRead: 1,
            longOutput: 45
        ),
        "gpt-5.5-pro": Price(input: 30, cacheRead: 30, output: 180),
    ]

    private nonisolated static let claudePrices: [String: Price] = [
        "claude-fable-5": Price(input: 10, cacheRead: 1, cacheWrite: 12.5, cacheWrite1h: 20, output: 50),
        "claude-opus-5": Price(input: 5, cacheRead: 0.5, cacheWrite: 6.25, cacheWrite1h: 10, output: 25),
        "claude-sonnet-5": Price(input: 2, cacheRead: 0.2, cacheWrite: 2.5, cacheWrite1h: 4, output: 10),
        "claude-opus-4-8": Price(input: 5, cacheRead: 0.5, cacheWrite: 6.25, cacheWrite1h: 10, output: 25),
        "claude-opus-4-7": Price(input: 5, cacheRead: 0.5, cacheWrite: 6.25, cacheWrite1h: 10, output: 25),
        "claude-opus-4-6": Price(input: 5, cacheRead: 0.5, cacheWrite: 6.25, cacheWrite1h: 10, output: 25),
        "claude-opus-4-5": Price(input: 5, cacheRead: 0.5, cacheWrite: 6.25, cacheWrite1h: 10, output: 25),
        "claude-sonnet-4-6": Price(input: 3, cacheRead: 0.3, cacheWrite: 3.75, cacheWrite1h: 6, output: 15),
        "claude-sonnet-4-5": Price(
            input: 3,
            cacheRead: 0.3,
            cacheWrite: 3.75,
            cacheWrite1h: 6,
            output: 15,
            threshold: 200_000,
            longInput: 6,
            longCacheRead: 0.6,
            longCacheWrite: 7.5,
            longOutput: 22.5
        ),
        "claude-sonnet-4": Price(
            input: 3,
            cacheRead: 0.3,
            cacheWrite: 3.75,
            cacheWrite1h: 6,
            output: 15,
            threshold: 200_000,
            longInput: 6,
            longCacheRead: 0.6,
            longCacheWrite: 7.5,
            longOutput: 22.5
        ),
        "claude-haiku-4-5": Price(input: 1, cacheRead: 0.1, cacheWrite: 1.25, cacheWrite1h: 2, output: 5),
    ]

    private nonisolated static let qwenPrices: [String: Price] = [
        "qwen3-coder": Price(input: 0.22, cacheRead: 0, output: 1.8),
        "qwen3-coder-30b-a3b-instruct": Price(input: 0.07, cacheRead: 0, output: 0.27),
        "qwen3-coder-flash": Price(input: 0.195, cacheRead: 0.039, cacheWrite: 0.24375, output: 0.975),
        "qwen3-coder-next": Price(input: 0.11, cacheRead: 0.07, output: 0.8),
        "qwen3-coder-plus": Price(input: 0.65, cacheRead: 0.13, cacheWrite: 0.8125, output: 3.25),
        "qwen3.7-plus": Price(input: 0.39, cacheRead: 0.078, cacheWrite: 0.49, output: 1.16),
    ]

    nonisolated static func normalize(_ model: String, provider: AIUsageProvider) -> String {
        var value = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch provider {
        case .codex where value.hasPrefix("openai/"):
            value.removeFirst("openai/".count)
        case .claude where value.hasPrefix("anthropic/"):
            value.removeFirst("anthropic/".count)
        case .claude where value.hasPrefix("anthropic."):
            value.removeFirst("anthropic.".count)
        case .qwen where value.hasPrefix("qwen/"):
            value.removeFirst("qwen/".count)
        default:
            break
        }
        if case .qwen = provider {
            value = value.replacingOccurrences(of: " ", with: "-")
            if value == "qwen-latest-series-invite-beta-v23" { return "qwen3.7-plus" }
        }
        if case .claude = provider,
            let lastDot = value.lastIndex(of: ".")
        {
            let tail = String(value[value.index(after: lastDot)...])
            if tail.hasPrefix("claude-") { value = tail }
        }
        if case .claude = provider,
            let range = value.range(of: #"-v\d+:\d+$"#, options: .regularExpression)
        {
            value.removeSubrange(range)
        }
        if case .codex = provider,
            let range = value.range(of: #"-\d{4}-\d{2}-\d{2}$"#, options: .regularExpression)
        {
            value.removeSubrange(range)
        }
        if let range = value.range(of: #"-\d{8}$"#, options: .regularExpression) {
            value.removeSubrange(range)
        }
        if case .codex = provider, value == "gpt-5.6" { return "gpt-5.6-sol" }
        return value
    }

    nonisolated static func estimatedCostUSD(
        provider: AIUsageProvider,
        model: String,
        date: Date,
        inputTokens: UInt64,
        cacheReadTokens: UInt64,
        cacheWriteTokens: UInt64,
        cacheWrite1hTokens: UInt64 = 0,
        outputTokens: UInt64
    ) -> Double? {
        guard let price = price(provider: provider, model: model, date: date) else { return nil }
        let inputTotal = inputTokens + cacheReadTokens + cacheWriteTokens
        let usesLongContext = price.threshold.map { inputTotal > $0 } ?? false
        let inputRate = usesLongContext ? price.longInput ?? price.input : price.input
        let cacheReadRate = usesLongContext ? price.longCacheRead ?? price.cacheRead : price.cacheRead
        let cacheWriteRate = usesLongContext ? price.longCacheWrite ?? price.cacheWrite : price.cacheWrite
        let outputRate = usesLongContext ? price.longOutput ?? price.output : price.output
        let oneHourWrites = min(cacheWriteTokens, cacheWrite1hTokens)
        let regularWrites = cacheWriteTokens - oneHourWrites
        let oneHourRate = usesLongContext ? (price.longInput ?? price.input) * 2 : price.cacheWrite1h

        return
            (Double(inputTokens) * inputRate
            + Double(cacheReadTokens) * cacheReadRate
            + Double(regularWrites) * cacheWriteRate
            + Double(oneHourWrites) * oneHourRate
            + Double(outputTokens) * outputRate) / 1_000_000
    }

    private nonisolated static func price(provider: AIUsageProvider, model: String, date: Date) -> Price? {
        let normalized = normalize(model, provider: provider)
        switch provider {
        case .codex:
            if normalized == "gpt-5.6-sol" {
                let current = Price(
                    input: 4,
                    cacheRead: 0.4,
                    cacheWrite: 5,
                    output: 20,
                    threshold: 272_000,
                    longInput: 8,
                    longCacheRead: 0.8,
                    longCacheWrite: 10,
                    longOutput: 30
                )
                return date >= Date(timeIntervalSince1970: 1_787_270_400)
                    ? current
                    : Price(
                        input: 5,
                        cacheRead: 0.5,
                        cacheWrite: 6.25,
                        output: 30,
                        threshold: 272_000,
                        longInput: 10,
                        longCacheRead: 1,
                        longCacheWrite: 12.5,
                        longOutput: 45
                    )
            }
            if normalized == "gpt-5.6-terra" {
                return date >= Date(timeIntervalSince1970: 1_785_369_600)
                    ? longContextPrice(input: 2, output: 12)
                    : longContextPrice(input: 2.5, output: 15)
            }
            if normalized == "gpt-5.6-luna" {
                return date >= Date(timeIntervalSince1970: 1_785_369_600)
                    ? longContextPrice(input: 0.2, output: 1.2)
                    : longContextPrice(input: 1, output: 6)
            }
            if let exact = codexPrices[normalized] { return exact }
        case .claude:
            if let exact = claudePrices[normalized] { return exact }
        case .qwen:
            if let exact = qwenPrices[normalized] { return exact }
        }
        return nil
    }

    private nonisolated static func longContextPrice(input: Double, output: Double) -> Price {
        Price(
            input: input,
            cacheRead: input * 0.1,
            cacheWrite: input * 1.25,
            output: output,
            threshold: 272_000,
            longInput: input * 2,
            longCacheRead: input * 0.2,
            longCacheWrite: input * 2.5,
            longOutput: output * 1.5
        )
    }
}
