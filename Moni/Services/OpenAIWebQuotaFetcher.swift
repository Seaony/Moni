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
        case noDiaProfile
        case noCookies
        case loginRequired
        case dashboardUnavailable

        var errorDescription: String? {
            switch self {
            case .noDiaProfile:
                "Code Review quota unavailable: no Dia profile was found."
            case .noCookies:
                "Code Review quota unavailable: sign in to ChatGPT in Dia, then refresh."
            case .loginRequired:
                "Code Review quota unavailable: the Dia ChatGPT session requires sign-in."
            case .dashboardUnavailable:
                "Code Review quota is not present on the Codex usage dashboard."
            }
        }
    }

    private let usageURL = URL(string: "https://chatgpt.com/codex/cloud/settings/analytics#usage")!
    private let cookieClient = BrowserCookieClient()
    private var cachedResult: (date: Date, result: OpenAIWebQuotaResult)?
    private var webView: WKWebView?
    private var hostWindow: NSWindow?

    func fetch(force: Bool = false) async -> OpenAIWebQuotaResult {
        if !force,
           let cachedResult,
           Date().timeIntervalSince(cachedResult.date) < 300
        {
            return cachedResult.result
        }

        do {
            let result = try await fetchFromDia()
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

    private func fetchFromDia() async throws -> OpenAIWebQuotaResult {
        let stores = cookieClient.stores(for: .dia)
        guard !stores.isEmpty else { throw FetchError.noDiaProfile }

        let query = BrowserCookieQuery(
            domains: ["chatgpt.com", "openai.com"],
            domainMatch: .suffix,
            origin: .fixed(usageURL)
        )
        var foundCookies = false
        var requiresLogin = false

        for store in stores {
            let cookies: [HTTPCookie]
            do {
                cookies = try cookieClient.cookies(matching: query, in: store)
            } catch {
                continue
            }
            guard !cookies.isEmpty else { continue }
            foundCookies = true

            let dataStore = WKWebsiteDataStore.nonPersistent()
            for cookie in cookies {
                await dataStore.httpCookieStore.setCookie(cookie)
            }
            prepareWebView(dataStore: dataStore)

            do {
                let body = try await loadDashboardBody()
                if let window = Self.parseCodeReviewWindow(from: body) {
                    return OpenAIWebQuotaResult(window: window, message: nil)
                }
            } catch FetchError.loginRequired {
                requiresLogin = true
            }
        }

        if requiresLogin { throw FetchError.loginRequired }
        if !foundCookies { throw FetchError.noCookies }
        throw FetchError.dashboardUnavailable
    }

    private func prepareWebView(dataStore: WKWebsiteDataStore) {
        hostWindow?.orderOut(nil)
        hostWindow = nil
        webView = nil

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

    private func loadDashboardBody() async throws -> String {
        guard let webView else { throw FetchError.dashboardUnavailable }

        var request = URLRequest(url: usageURL)
        request.timeoutInterval = 15
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        webView.load(request)

        let deadline = Date().addingTimeInterval(15)
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
                throw FetchError.loginRequired
            }
        }

        if sawLogin { throw FetchError.loginRequired }
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
