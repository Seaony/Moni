import AppKit
import Foundation
import SweetCookieKit
import WebKit

struct OpenAIWebQuotaResult: Sendable {
    let window: AIQuotaWindow?
    let message: String?
}

@MainActor
final class OpenAIWebQuotaFetcher {
    static let shared = OpenAIWebQuotaFetcher()

    private enum FetchError: LocalizedError {
        case noBrowserProfile
        case noCookies
        case loginRequired(String)
        case dashboardUnavailable

        var errorDescription: String? {
            switch self {
            case .noBrowserProfile:
                "Code Review quota unavailable: no supported browser profile was found."
            case .noCookies:
                "Code Review quota unavailable: sign in to ChatGPT in your browser, then refresh."
            case .loginRequired(let hint):
                "Code Review quota unavailable: the ChatGPT session in \(hint) needs signing in again."
            case .dashboardUnavailable:
                "Code Review quota is not present on the Codex usage dashboard."
            }
        }
    }

    /// Thrown by the dashboard load when the page bounced to a sign-in screen; the
    /// caller turns it into `FetchError.loginRequired` once it knows which
    /// browsers were tried.
    private struct SignedOut: Error {}

    /// Rendering the dashboard is the expensive part, so cap how many signed-in
    /// profiles are worth trying and how long the whole attempt may take — this
    /// runs on a background refresh cycle.
    private static let maximumProfileAttempts = 3
    private static let profileBudget: TimeInterval = 15
    private static let totalBudget: TimeInterval = 30

    private let usageURL = URL(string: "https://chatgpt.com/codex/cloud/settings/analytics#usage")!
    private let cookieClient = BrowserCookieClient()
    private var cachedResult: (date: Date, result: OpenAIWebQuotaResult)?
    private var webView: WKWebView?
    private var hostWindow: NSWindow?

    func fetch(force: Bool = false, allowKeychainPrompt: Bool = false) async -> OpenAIWebQuotaResult {
        if !force,
           let cachedResult,
           Date().timeIntervalSince(cachedResult.date) < 300
        {
            return cachedResult.result
        }

        defer { teardownWebView() }
        do {
            let result = try await fetchFromBrowsers(allowKeychainPrompt: allowKeychainPrompt)
            cachedResult = (Date(), result)
            return result
        } catch let error as FetchError {
            return OpenAIWebQuotaResult(window: nil, message: error.localizedDescription)
        } catch let error as BrowserCookieError {
            return OpenAIWebQuotaResult(
                window: nil,
                message: "Code Review quota unavailable: \(error.localizedDescription)"
            )
        } catch {
            return OpenAIWebQuotaResult(
                window: nil,
                message: "Code Review quota request failed: \(error.localizedDescription)"
            )
        }
    }

    private func fetchFromBrowsers(allowKeychainPrompt: Bool) async throws -> OpenAIWebQuotaResult {
        let query = BrowserCookieQuery(
            domains: ["chatgpt.com", "openai.com"],
            domainMatch: .suffix,
            origin: .fixed(usageURL)
        )

        // Enumerating profiles and reading cookies is cheap compared with
        // rendering the dashboard, but it is still filesystem walks plus SQLite
        // and AES per profile, so it runs off the main actor. Only the profiles
        // that actually hold a ChatGPT session pay for a WebView.
        let client = cookieClient
        let scan = await Task.detached(priority: .utility) {
            Self.scanBrowsers(matching: query, client: client, allowKeychainPrompt: allowKeychainPrompt)
        }.value
        guard scan.hasProfiles else { throw FetchError.noBrowserProfile }
        let candidates = scan.candidates
        guard !candidates.isEmpty else { throw FetchError.noCookies }

        var requiresLogin = false
        let overallDeadline = Date().addingTimeInterval(Self.totalBudget)

        for candidate in candidates.prefix(Self.maximumProfileAttempts) {
            guard Date() < overallDeadline else { break }

            let dataStore = WKWebsiteDataStore.nonPersistent()
            for cookie in BrowserCookieClient.makeHTTPCookies(candidate.records, origin: query.origin) {
                await dataStore.httpCookieStore.setCookie(cookie)
            }
            prepareWebView(dataStore: dataStore)

            do {
                let body = try await loadDashboardBody(
                    deadline: min(overallDeadline, Date().addingTimeInterval(Self.profileBudget))
                )
                if let window = Self.parseCodeReviewWindow(from: body) {
                    return OpenAIWebQuotaResult(window: window, message: nil)
                }
            } catch is SignedOut {
                requiresLogin = true
            }
        }

        if requiresLogin {
            var tried: [Browser] = []
            for candidate in candidates.prefix(Self.maximumProfileAttempts)
            where !tried.contains(candidate.store.browser) {
                tried.append(candidate.store.browser)
            }
            throw FetchError.loginRequired(tried.loginHint)
        }
        throw FetchError.dashboardUnavailable
    }

    /// Chromium profiles keep their cookie key in the Keychain, and the library
    /// fetches that key before it looks at a single row — so every installed
    /// Chromium browser can raise its own authorization dialog. Interaction is
    /// therefore only allowed when the user explicitly asked for a refresh;
    /// automatic refreshes read what is already authorized and skip the rest.
    private struct BrowserScan: Sendable {
        let hasProfiles: Bool
        let candidates: [(store: BrowserCookieStore, records: [BrowserCookieRecord])]
    }

    private nonisolated static func scanBrowsers(
        matching query: BrowserCookieQuery,
        client: BrowserCookieClient,
        allowKeychainPrompt: Bool
    ) -> BrowserScan {
        let stores = client.stores(in: Browser.defaultImportOrder)
        let read = {
            stores.compactMap { store -> (store: BrowserCookieStore, records: [BrowserCookieRecord])? in
                let records = (try? client.records(matching: query, in: store)) ?? []
                return records.isEmpty ? nil : (store, records)
            }
        }
        let candidates = allowKeychainPrompt
            ? read()
            : BrowserCookieKeychainAccessGate.withUserInteractionDisallowed(read)
        return BrowserScan(hasProfiles: !stores.isEmpty, candidates: candidates)
    }

    /// The host window has to be on screen for WebKit to keep running scripts, so
    /// it must be closed again once the scrape finishes — otherwise a menu-bar app
    /// leaves a live chatgpt.com web process and a stray window running forever.
    private func teardownWebView() {
        webView?.stopLoading()
        webView?.removeFromSuperview()
        webView = nil
        hostWindow?.contentView = nil
        hostWindow?.orderOut(nil)
        hostWindow?.close()
        hostWindow = nil
    }

    private func prepareWebView(dataStore: WKWebsiteDataStore) {
        teardownWebView()

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1_100, height: 1_200), configuration: configuration)
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/605.1.15 Safari/605.1.15"

        let window = NSWindow(
            contentRect: webView.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        // Code-created NSWindows release themselves on close, which double-frees
        // under ARC once `hostWindow` also releases it.
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.alphaValue = 0.001
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.collectionBehavior = [.transient, .ignoresCycle]
        if let visibleFrame = NSScreen.main?.visibleFrame {
            window.setFrameOrigin(NSPoint(x: visibleFrame.maxX - 1, y: visibleFrame.maxY - 1))
        }
        window.orderFrontRegardless()

        self.webView = webView
        hostWindow = window
    }

    private func loadDashboardBody(deadline: Date) async throws -> String {
        guard let webView else { throw FetchError.dashboardUnavailable }

        var request = URLRequest(url: usageURL)
        request.timeoutInterval = Self.profileBudget
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        webView.load(request)

        var sawLogin = false
        while Date() < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(500))

            let href = (try? await webView.evaluateJavaScript("String(location.href)")) as? String ?? ""
            let body = (try? await webView.evaluateJavaScript("document.body ? String(document.body.innerText || '') : ''")) as? String ?? ""
            let lower = body.lowercased()
            sawLogin = sawLogin
                || href.contains("/auth/")
                || href.contains("/login")
                || lower.contains("log in to chatgpt")
                || lower.contains("sign in to chatgpt")

            if Self.parseCodeReviewWindow(from: body) != nil {
                return body
            }
            if sawLogin, !webView.isLoading {
                throw SignedOut()
            }
        }

        if sawLogin { throw SignedOut() }
        throw FetchError.dashboardUnavailable
    }

    private static func parseCodeReviewWindow(from body: String, now: Date = Date()) -> AIQuotaWindow? {
        let lines = body
            .replacingOccurrences(of: "\r", with: "\n")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for index in lines.indices {
            let lower = lines[index].lowercased()
            guard lower.contains("code review") || lower.contains("core review") else { continue }
            guard !lower.contains("github code review") else { continue }

            let end = min(lines.count - 1, index + 5)
            let nearby = Array(lines[index...end])
            guard let remaining = nearby.compactMap(parseRemainingPercent).first else { continue }
            let resetsAt = nearby.compactMap { parseResetDate($0, now: now) }.first
            return AIQuotaWindow(
                id: "codex-code-review",
                label: "Code review",
                usedPercent: 100 - remaining,
                windowMinutes: 10_080,
                resetsAt: resetsAt
            )
        }
        return nil
    }

    private static func parseRemainingPercent(_ line: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: #"([0-9]{1,3})\s*%"#),
              let match = regex.firstMatch(
                  in: line,
                  range: NSRange(line.startIndex..<line.endIndex, in: line)
              ),
              let range = Range(match.range(at: 1), in: line),
              let value = Double(line[range])
        else { return nil }

        let lower = line.lowercased()
        if lower.contains("used") || lower.contains("spent") || lower.contains("consumed") {
            return min(100, max(0, 100 - value))
        }
        return min(100, max(0, value))
    }

    private static func parseResetDate(_ line: String, now: Date) -> Date? {
        let lower = line.lowercased()
        guard lower.contains("reset") else { return nil }

        if let regex = try? NSRegularExpression(
            pattern: #"(?:in\s*)?(?:(\d+)\s*d(?:ays?)?)?\s*(?:(\d+)\s*h(?:ours?)?)?\s*(?:(\d+)\s*m(?:in(?:utes?)?)?)?"#,
            options: [.caseInsensitive]
        ) {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            for match in regex.matches(in: line, range: range) where match.numberOfRanges == 4 {
                let days = number(in: line, range: match.range(at: 1)) ?? 0
                let hours = number(in: line, range: match.range(at: 2)) ?? 0
                let minutes = number(in: line, range: match.range(at: 3)) ?? 0
                let seconds = days * 86_400 + hours * 3_600 + minutes * 60
                if seconds > 0 { return now.addingTimeInterval(TimeInterval(seconds)) }
            }
        }

        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else {
            return nil
        }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        return detector.firstMatch(in: line, range: range)?.date
    }

    private static func number(in text: String, range: NSRange) -> Int? {
        guard range.location != NSNotFound, let range = Range(range, in: text) else { return nil }
        return Int(text[range])
    }
}
