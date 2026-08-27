import Foundation
import Security

nonisolated struct AIQuotaFetchResult: Codable, Sendable {
    let planName: String?
    let windows: [AIQuotaWindow]
    let message: String?
}

nonisolated enum AIQuotaFetcher {
    private struct ClaudeCredentials: Sendable {
        let accessToken: String
        let refreshToken: String?
        let expiresAt: Date?
        let scopes: [String]
        let rateLimitTier: String?
        let subscriptionType: String?

        var needsRefresh: Bool {
            expiresAt.map { $0.timeIntervalSinceNow <= 60 } ?? false
        }
    }

    private static let claudeCacheService = "com.seaony.Moni.claude-oauth-cache"
    private static let claudeCacheAccount = "claudeAiOauth"
    private static let claudeOAuthClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    /// `disabledProviders` are the ones switched off in Settings. Skipping them
    /// here is what makes the switch mean "stop touching my account" instead of
    /// merely hiding the card while still calling the API and the Keychain.
    static func fetchAll(
        homeDirectory: URL,
        allowKeychainPrompt: Bool = false,
        disabledProviders: Set<String> = []
    ) async -> [String: AIQuotaFetchResult] {
        async let codex = disabledProviders.contains("Codex")
            ? nil
            : fetchCodex(homeDirectory: homeDirectory)
        async let claude = disabledProviders.contains("Claude")
            ? nil
            : fetchClaude(
                homeDirectory: homeDirectory,
                allowKeychainPrompt: allowKeychainPrompt
            )
        var results: [String: AIQuotaFetchResult] = [:]
        if let codex = await codex { results["Codex"] = codex }
        if let claude = await claude { results["Claude"] = claude }
        return results
    }

    private static func fetchCodex(homeDirectory: URL) async -> AIQuotaFetchResult {
        let authURL = homeDirectory.appending(path: ".codex/auth.json")
        guard let authData = try? Data(contentsOf: authURL),
            let root = try? JSONSerialization.jsonObject(with: authData) as? [String: Any],
            let tokens = root["tokens"] as? [String: Any],
            let accessToken = nonEmptyString(tokens["access_token"])
        else {
            return AIQuotaFetchResult(
                planName: nil,
                windows: [],
                message: "Codex API quota unavailable: sign in to Codex first."
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
                    guard !title.localizedCaseInsensitiveContains("code review") else { continue }
                    appendCodexWindows(
                        from: rateLimit,
                        title: title,
                        idPrefix: "codex-extra-\(index)",
                        to: &windows
                    )
                }
            }
            guard !windows.isEmpty else {
                return AIQuotaFetchResult(
                    planName: codexPlan(nonEmptyString(json["plan_type"])),
                    windows: [],
                    message: "Codex did not return any quota windows."
                )
            }
            return AIQuotaFetchResult(
                planName: codexPlan(nonEmptyString(json["plan_type"])),
                windows: windows,
                message: nil
            )
        } catch let error as QuotaFetchError {
            return AIQuotaFetchResult(
                planName: nil,
                windows: [],
                message: error.codexMessage
            )
        } catch {
            return AIQuotaFetchResult(
                planName: nil,
                windows: [],
                message: "Codex quota request failed."
            )
        }
    }

    private static func fetchClaude(
        homeDirectory: URL,
        allowKeychainPrompt: Bool
    ) async -> AIQuotaFetchResult {
        guard let credentials = await claudeCredentials(
            homeDirectory: homeDirectory,
            allowKeychainPrompt: allowKeychainPrompt
        ) else {
            return AIQuotaFetchResult(
                planName: nil,
                windows: [],
                message: "Claude quota unavailable: authorize Keychain access from Refresh."
            )
        }

        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            return AIQuotaFetchResult(planName: nil, windows: [], message: "Claude quota endpoint is invalid.")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
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

    private static func claudeCredentials(
        homeDirectory: URL,
        allowKeychainPrompt: Bool
    ) async -> ClaudeCredentials? {
        if let cached = cachedClaudeCredentials(),
            let credentials = await usableClaudeCredentials(cached)
        {
            return credentials
        }

        let fileURL = homeDirectory.appending(path: ".claude/.credentials.json")
        if let data = try? Data(contentsOf: fileURL),
            let candidate = claudeOAuth(from: data),
            let credentials = await usableClaudeCredentials(candidate)
        {
            saveClaudeCredentials(credentials)
            return credentials
        }

        guard let candidate = claudeKeychainCredentials(allowPrompt: allowKeychainPrompt),
            let credentials = await usableClaudeCredentials(candidate)
        else { return nil }
        saveClaudeCredentials(credentials)
        return credentials
    }

    private static func cachedClaudeCredentials() -> ClaudeCredentials? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: claudeCacheService,
            kSecAttrAccount as String: claudeCacheAccount,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        KeychainNoUIQuery.apply(to: &query)
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data
        else { return nil }
        return claudeOAuth(from: data)
    }

    private static func claudeKeychainCredentials(allowPrompt: Bool) -> ClaudeCredentials? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        if !allowPrompt {
            KeychainNoUIQuery.apply(to: &query)
        }
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data
        else { return nil }
        return claudeOAuth(from: data)
    }

    private static func claudeOAuth(from data: Data) -> ClaudeCredentials? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let oauth = root["claudeAiOauth"] as? [String: Any],
            let accessToken = nonEmptyString(oauth["accessToken"])
        else { return nil }
        return ClaudeCredentials(
            accessToken: accessToken,
            refreshToken: nonEmptyString(oauth["refreshToken"]),
            expiresAt: double(oauth["expiresAt"]).map { Date(timeIntervalSince1970: $0 / 1000) },
            scopes: oauth["scopes"] as? [String] ?? [],
            rateLimitTier: nonEmptyString(oauth["rateLimitTier"]),
            subscriptionType: nonEmptyString(oauth["subscriptionType"])
        )
    }

    private static func usableClaudeCredentials(
        _ credentials: ClaudeCredentials
    ) async -> ClaudeCredentials? {
        guard credentials.needsRefresh else { return credentials }
        return await refreshClaudeCredentials(credentials)
    }

    private static func refreshClaudeCredentials(
        _ credentials: ClaudeCredentials
    ) async -> ClaudeCredentials? {
        guard let refreshToken = credentials.refreshToken,
            let url = URL(string: "https://platform.claude.com/v1/oauth/token")
        else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "client_id", value: claudeOAuthClientID),
        ]
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        guard let json = try? await responseJSON(for: request),
            let accessToken = nonEmptyString(json["access_token"]),
            let expiresIn = double(json["expires_in"])
        else { return nil }
        let refreshed = ClaudeCredentials(
            accessToken: accessToken,
            refreshToken: nonEmptyString(json["refresh_token"]) ?? refreshToken,
            expiresAt: Date().addingTimeInterval(expiresIn),
            scopes: credentials.scopes,
            rateLimitTier: credentials.rateLimitTier,
            subscriptionType: credentials.subscriptionType
        )
        saveClaudeCredentials(refreshed)
        return refreshed
    }

    private static func saveClaudeCredentials(_ credentials: ClaudeCredentials) {
        var oauth: [String: Any] = [
            "accessToken": credentials.accessToken,
            "scopes": credentials.scopes,
        ]
        if let refreshToken = credentials.refreshToken { oauth["refreshToken"] = refreshToken }
        if let expiresAt = credentials.expiresAt {
            oauth["expiresAt"] = expiresAt.timeIntervalSince1970 * 1000
        }
        if let rateLimitTier = credentials.rateLimitTier { oauth["rateLimitTier"] = rateLimitTier }
        if let subscriptionType = credentials.subscriptionType { oauth["subscriptionType"] = subscriptionType }
        guard let data = try? JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth]) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: claudeCacheService,
            kSecAttrAccount as String: claudeCacheAccount,
        ]
        let status = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        guard status == errSecItemNotFound else { return }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
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

    private static func claudePlan(_ credentials: ClaudeCredentials) -> String? {
        let subscription = formattedPlan(credentials.subscriptionType)
        let tier = credentials.rateLimitTier?.lowercased()
        if tier?.contains("20x") == true { return "Max 20x" }
        if tier?.contains("5x") == true { return "Max 5x" }
        return subscription
    }

    static func codexPlan(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty
        else { return nil }
        switch value.lowercased() {
        case "pro": return "Pro 20x"
        case "prolite", "pro_lite", "pro-lite", "pro lite": return "Pro 5x"
        default: return formattedPlan(value)
        }
    }

    private static func formattedPlan(_ value: String?) -> String? {
        guard let value else { return nil }
        return value.replacingOccurrences(of: "_", with: " ").capitalized
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
