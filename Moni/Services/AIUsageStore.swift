import Combine
import Foundation

@MainActor
final class AIUsageStore: ObservableObject {
    @Published private(set) var summary = AIUsageSummary()
    @Published private(set) var isLoading = false

    private let scanner = AIUsageScanner()

    init() {
        refresh()
    }

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        Task {
            summary = await scanner.scan()
            isLoading = false
        }
    }
}

actor AIUsageScanner {
    private struct Totals {
        var total: UInt64 = 0
        var input: UInt64 = 0
        var output: UInt64 = 0
        var cached: UInt64 = 0
        var reasoning: UInt64 = 0
        var sessions = 0
        var models: [String: UInt64] = [:]
        var lastUpdated: Date?
    }

    private let fileManager = FileManager.default
    private let calendar = Calendar.current
    private let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let fallbackFormatter = ISO8601DateFormatter()

    func scan() -> AIUsageSummary {
        let cutoff = calendar.date(byAdding: .day, value: -30, to: Date()) ?? .distantPast
        var daily: [Date: UInt64] = [:]
        let codex = scanCodex(cutoff: cutoff, daily: &daily)
        let claude = scanClaude(cutoff: cutoff, daily: &daily)
        let providers = [provider("Codex", totals: codex), provider("Claude", totals: claude)]
            .filter { $0.totalTokens > 0 || $0.sessionCount > 0 }
        return AIUsageSummary(
            providers: providers,
            daily: daily.map { DailyAIUsage(date: $0.key, tokens: $0.value) }.sorted { $0.date < $1.date },
            scannedAt: Date()
        )
    }

    private func scanCodex(cutoff: Date, daily: inout [Date: UInt64]) -> Totals {
        let home = fileManager.homeDirectoryForCurrentUser
        let roots = [
            home.appending(path: ".codex/sessions"),
            home.appending(path: ".codex/archived_sessions")
        ]
        var result = Totals()

        for url in jsonlFiles(in: roots, modifiedAfter: cutoff) {
            var model: String?
            var maximum: [String: UInt64] = [:]
            var usageDate: Date?

            enumerateLines(in: url) { line in
                guard line.contains("\"turn_context\"") || line.contains("\"token_count\"") else { return }
                guard let object = json(line), let type = object["type"] as? String, let payload = object["payload"] as? [String: Any] else { return }
                if type == "turn_context" {
                    model = payload["model"] as? String ?? model
                } else if type == "event_msg", payload["type"] as? String == "token_count",
                          let info = payload["info"] as? [String: Any],
                          let total = info["total_token_usage"] as? [String: Any] {
                    let totalTokens = uint(total["total_tokens"])
                    if totalTokens >= uint(maximum["total_tokens"]) {
                        maximum = total.compactMapValues { value in uint(value) }
                        usageDate = date(object["timestamp"])
                    }
                }
            }

            guard uint(maximum["total_tokens"]) > 0 else { continue }
            result.sessions += 1
            add(maximum, model: model, date: usageDate, to: &result, daily: &daily)
        }
        return result
    }

    private func scanClaude(cutoff: Date, daily: inout [Date: UInt64]) -> Totals {
        let root = fileManager.homeDirectoryForCurrentUser.appending(path: ".claude/projects")
        var result = Totals()

        for url in jsonlFiles(in: [root], modifiedAfter: cutoff) {
            var sessionHasUsage = false
            enumerateLines(in: url) { line in
                guard line.contains("\"usage\"") else { return }
                guard let object = json(line),
                      let message = object["message"] as? [String: Any],
                      let usage = message["usage"] as? [String: Any] else { return }

                let input = uint(usage["input_tokens"])
                let output = uint(usage["output_tokens"])
                let cached = uint(usage["cache_read_input_tokens"]) + uint(usage["cache_creation_input_tokens"])
                let total = input + output + cached
                guard total > 0 else { return }

                sessionHasUsage = true
                let timestamp = date(object["timestamp"])
                result.total += total
                result.input += input
                result.output += output
                result.cached += cached
                if let model = message["model"] as? String {
                    result.models[model, default: 0] += total
                }
                updateLast(timestamp, in: &result)
                addDaily(total, at: timestamp, to: &daily)
            }
            if sessionHasUsage { result.sessions += 1 }
        }
        return result
    }

    private func add(
        _ usage: [String: UInt64],
        model: String?,
        date: Date?,
        to totals: inout Totals,
        daily: inout [Date: UInt64]
    ) {
        let total = uint(usage["total_tokens"])
        totals.total += total
        totals.input += uint(usage["input_tokens"])
        totals.output += uint(usage["output_tokens"])
        totals.cached += uint(usage["cached_input_tokens"]) + uint(usage["cache_write_input_tokens"])
        totals.reasoning += uint(usage["reasoning_output_tokens"])
        if let model { totals.models[model, default: 0] += total }
        updateLast(date, in: &totals)
        addDaily(total, at: date, to: &daily)
    }

    private func provider(_ name: String, totals: Totals) -> AIProviderUsage {
        AIProviderUsage(
            provider: name,
            totalTokens: totals.total,
            inputTokens: totals.input,
            outputTokens: totals.output,
            cachedTokens: totals.cached,
            reasoningTokens: totals.reasoning,
            sessionCount: totals.sessions,
            topModel: totals.models.max { $0.value < $1.value }?.key,
            lastUpdated: totals.lastUpdated
        )
    }

    private func jsonlFiles(in roots: [URL], modifiedAfter cutoff: Date) -> [URL] {
        var files: [URL] = []
        for root in roots {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in enumerator {
                guard url.pathExtension == "jsonl",
                      let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                      values.isRegularFile == true,
                      values.contentModificationDate ?? .distantPast >= cutoff else { continue }
                files.append(url)
            }
        }
        return files
    }

    private func enumerateLines(in url: URL, body: (String) -> Void) {
        guard let string = try? String(contentsOf: url, encoding: .utf8) else { return }
        for line in string.split(whereSeparator: \.isNewline) {
            body(String(line))
        }
    }

    private func json(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func date(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        return formatter.date(from: string) ?? fallbackFormatter.date(from: string)
    }

    private func uint(_ value: Any?) -> UInt64 {
        if let value = value as? UInt64 { return value }
        if let value = value as? Int { return UInt64(max(0, value)) }
        if let value = value as? NSNumber { return value.uint64Value }
        return 0
    }

    private func updateLast(_ date: Date?, in totals: inout Totals) {
        guard let date, date > totals.lastUpdated ?? .distantPast else { return }
        totals.lastUpdated = date
    }

    private func addDaily(_ tokens: UInt64, at date: Date?, to daily: inout [Date: UInt64]) {
        guard let date else { return }
        daily[calendar.startOfDay(for: date), default: 0] += tokens
    }
}
