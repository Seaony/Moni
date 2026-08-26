import Foundation
import Security

struct AIQuotaFetchResult: Sendable {
    let planName: String?
    let windows: [AIQuotaWindow]
    let message: String?
}

enum AIQuotaFetcher {
    static func fetchAll(homeDirectory: URL) async -> [String: AIQuotaFetchResult] {
        async let codex = fetchCodex(homeDirectory: homeDirectory)
        async let claude = fetchClaude(homeDirectory: homeDirectory)
        return await ["Codex": codex, "Claude": claude]
    }

    private static func fetchCodex(homeDirectory: URL) async -> AIQuotaFetchResult {
        let webQuota = await OpenAIWebQuotaFetcher.shared.fetch()
        let authURL = homeDirectory.appending(path: ".codex/auth.json")
        guard let authData = try? Data(contentsOf: authURL),
            let root = try? JSONSerialization.jsonObject(with: authData) as? [String: Any],
            let tokens = root["tokens"] as? [String: Any],
            let accessToken = nonEmptyString(tokens["access_token"])
        else {
            return AIQuotaFetchResult(
                planName: nil,
                windows: webQuota.window.map { [$0] } ?? [],
                message: joinedMessage(
                    "Codex API quota unavailable: sign in to Codex first.",
                    webQuota.message
                )
            )
        }

        guard let url = URL(string: "https://chatgpt.com/backend-api/wham/usage") else {
            return AIQuotaFetchResult(planName: nil, windows: [], message: "Codex quota endpoint is invalid.")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("Moni", forHTTPHeaderField: "User-Agent")
        if let accountID = nonEmptyString(tokens["account_id"]) {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        do {
            let json = try await responseJSON(for: request)
            var windows: [AIQuotaWindow] = []
            if let rateLimit = json["rate_limit"] as? [String: Any] {
                appendCodexWindows(
                    from: rateLimit,
                    title: nil,
                    idPrefix: "codex",
                    to: &windows
                )
            }
            if let additional = json["additional_rate_limits"] as? [[String: Any]] {
                for (index, limit) in additional.enumerated() {
                    guard let rateLimit = limit["rate_limit"] as? [String: Any] else { continue }
                    let title = nonEmptyString(limit["limit_name"])
                        ?? nonEmptyString(limit["metered_feature"])
                        ?? "Additional limit"
                    appendCodexWindows(
                        from: rateLimit,
                        title: title,
                        idPrefix: "codex-extra-\(index)",
                        to: &windows
                    )
                }
            }
            if let window = webQuota.window,
               !windows.contains(where: { $0.id == window.id })
            {
                windows.append(window)
            }
            guard !windows.isEmpty else {
                return AIQuotaFetchResult(
                    planName: formattedPlan(nonEmptyString(json["plan_type"])),
                    windows: [],
                    message: joinedMessage(
                        "Codex did not return any quota windows.",
                        webQuota.message
                    )
                )
            }
            return AIQuotaFetchResult(
                planName: formattedPlan(nonEmptyString(json["plan_type"])),
                windows: windows,
                message: webQuota.message
            )
        } catch let error as QuotaFetchError {
            return AIQuotaFetchResult(
                planName: nil,
                windows: webQuota.window.map { [$0] } ?? [],
                message: joinedMessage(error.codexMessage, webQuota.message)
            )
        } catch {
            return AIQuotaFetchResult(
                planName: nil,
                windows: webQuota.window.map { [$0] } ?? [],
                message: joinedMessage("Codex quota request failed.", webQuota.message)
            )
        }
    }

    private static func fetchClaude(homeDirectory: URL) async -> AIQuotaFetchResult {
        guard let credentials = claudeCredentials(homeDirectory: homeDirectory),
            let accessToken = nonEmptyString(credentials["accessToken"])
        else {
            return AIQuotaFetchResult(
                planName: nil,
                windows: [],
                message: "Claude quota unavailable: allow Moni to read Claude Code credentials."
            )
        }

        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            return AIQuotaFetchResult(planName: nil, windows: [], message: "Claude quota endpoint is invalid.")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/2.1.0", forHTTPHeaderField: "User-Agent")

        do {
            let json = try await responseJSON(for: request)
            var windows: [AIQuotaWindow] = []
            appendClaudeWindow(json["five_hour"], id: "claude-five-hour", label: "5-hour window", minutes: 300, to: &windows)
            appendClaudeWindow(json["seven_day"], id: "claude-weekly", label: "Weekly", minutes: 10_080, to: &windows)
            appendClaudeWindow(json["seven_day_opus"], id: "claude-opus", label: "Opus only", minutes: 10_080, to: &windows)
            appendClaudeWindow(json["seven_day_sonnet"], id: "claude-sonnet", label: "Sonnet only", minutes: 10_080, to: &windows)
            appendClaudeWindow(json["seven_day_oauth_apps"], id: "claude-oauth", label: "OAuth apps", minutes: 10_080, to: &windows)
            appendClaudeScopedWindows(json["limits"], to: &windows)

            let plan = claudePlan(credentials)
            guard !windows.isEmpty else {
                return AIQuotaFetchResult(
                    planName: plan,
                    windows: [],
                    message: "Claude did not return any quota windows."
                )
            }
            return AIQuotaFetchResult(planName: plan, windows: windows, message: nil)
        } catch let error as QuotaFetchError {
            return AIQuotaFetchResult(planName: claudePlan(credentials), windows: [], message: error.claudeMessage)
        } catch {
            return AIQuotaFetchResult(
                planName: claudePlan(credentials),
                windows: [],
                message: "Claude quota request failed."
            )
        }
    }

    private static func claudeCredentials(homeDirectory: URL) -> [String: Any]? {
        let fileURL = homeDirectory.appending(path: ".claude/.credentials.json")
        if let data = try? Data(contentsOf: fileURL), let credentials = claudeOAuth(from: data) {
            return credentials
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data
        else { return nil }
        return claudeOAuth(from: data)
    }

    private static func claudeOAuth(from data: Data) -> [String: Any]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return root["claudeAiOauth"] as? [String: Any]
    }

    private static func appendCodexWindows(
        from rateLimit: [String: Any],
        title: String?,
        idPrefix: String,
        to windows: inout [AIQuotaWindow]
    ) {
        let candidates = [
            ("primary_window", "primary"),
            ("secondary_window", "secondary"),
        ]
        for (key, suffix) in candidates {
            guard let raw = rateLimit[key] as? [String: Any],
                let used = double(raw["used_percent"])
            else { continue }
            let minutes = int(raw["limit_window_seconds"]).map { $0 / 60 }
                ?? int(raw["window_minutes"])
            let label = codexWindowLabel(title: title, minutes: minutes)
            windows.append(
                AIQuotaWindow(
                    id: "\(idPrefix)-\(suffix)-\(minutes ?? 0)",
                    label: label,
                    usedPercent: used,
                    windowMinutes: minutes,
                    resetsAt: codexResetDate(raw)
                ))
        }
    }

    private static func codexResetDate(_ window: [String: Any]) -> Date? {
        if let date = epochDate(window["reset_at"] ?? window["resets_at"]) {
            return date
        }
        guard let seconds = double(window["reset_after_seconds"]), seconds >= 0 else { return nil }
        return Date().addingTimeInterval(seconds)
    }

    private static func appendClaudeWindow(
        _ value: Any?,
        id: String,
        label: String,
        minutes: Int,
        to windows: inout [AIQuotaWindow]
    ) {
        guard let raw = value as? [String: Any], let used = double(raw["utilization"]) else { return }
        windows.append(
            AIQuotaWindow(
                id: id,
                label: label,
                usedPercent: used,
                windowMinutes: minutes,
                resetsAt: isoDate(nonEmptyString(raw["resets_at"]))
            ))
    }

    private static func appendClaudeScopedWindows(_ value: Any?, to windows: inout [AIQuotaWindow]) {
        guard let limits = value as? [[String: Any]] else { return }
        for (index, limit) in limits.enumerated() {
            guard nonEmptyString(limit["kind"]) == "weekly_scoped",
                let used = double(limit["percent"])
            else { continue }
            let scope = limit["scope"] as? [String: Any]
            let model = scope?["model"] as? [String: Any]
            let name = nonEmptyString(model?["display_name"])
                ?? nonEmptyString(model?["id"])
                ?? "Model"
            windows.append(
                AIQuotaWindow(
                    id: "claude-scoped-\(index)-\(name)",
                    label: "\(name) only",
                    usedPercent: used,
                    windowMinutes: 10_080,
                    resetsAt: isoDate(nonEmptyString(limit["resets_at"]))
                ))
        }
    }

    private static func codexWindowLabel(title: String?, minutes: Int?) -> String {
        let isSpark = title?.localizedCaseInsensitiveContains("spark") == true
        switch minutes {
        case 300: return isSpark ? "Spark 5-hour" : "5-hour window"
        case 10_080: return isSpark ? "Spark weekly" : (title ?? "Weekly")
        default: return title ?? "Usage window"
        }
    }

    private static func claudePlan(_ credentials: [String: Any]) -> String? {
        let subscription = formattedPlan(nonEmptyString(credentials["subscriptionType"]))
        let tier = nonEmptyString(credentials["rateLimitTier"])?.lowercased()
        if tier?.contains("20x") == true { return "Max 20x" }
        if tier?.contains("5x") == true { return "Max 5x" }
        return subscription
    }

    private static func formattedPlan(_ value: String?) -> String? {
        guard let value else { return nil }
        return value.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private static func joinedMessage(_ first: String?, _ second: String?) -> String? {
        let messages: [String] = [first, second]
            .compactMap { value in
                guard let value else { return nil }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
        return messages.isEmpty ? nil : messages.joined(separator: " ")
    }

    private static func responseJSON(for request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard data.count <= 256 * 1_024 else { throw QuotaFetchError.invalidResponse }
        guard let http = response as? HTTPURLResponse else { throw QuotaFetchError.invalidResponse }
        guard http.statusCode == 200 else { throw QuotaFetchError.http(http.statusCode) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QuotaFetchError.invalidResponse
        }
        return json
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func double(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        return nil
    }

    private static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    private static func epochDate(_ value: Any?) -> Date? {
        guard let seconds = double(value), seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func isoDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

private enum QuotaFetchError: Error {
    case http(Int)
    case invalidResponse

    var codexMessage: String {
        switch self {
        case .http(401), .http(403): "Codex quota unavailable: sign in again."
        case .http: "Codex quota service is temporarily unavailable."
        case .invalidResponse: "Codex returned an invalid quota response."
        }
    }

    var claudeMessage: String {
        switch self {
        case .http(401), .http(403): "Claude quota unavailable: sign in again."
        case .http(429): "Claude quota is temporarily rate limited."
        case .http: "Claude quota service is temporarily unavailable."
        case .invalidResponse: "Claude returned an invalid quota response."
        }
    }
}
