import Combine
import Foundation

@MainActor
final class AIUsageStore: ObservableObject {
    private enum Query: Equatable {
        case days(Int)
        case range(AIUsageRange)
    }

    @Published private(set) var summary = AIUsageSummary()
    @Published private(set) var isLoading = false

    private let scanner = AIUsageScanner()
    private var completedQuery: Query?
    private var activeRequest: (query: Query, includeQuotas: Bool)?
    private var pendingRequest: (query: Query, includeQuotas: Bool)?

    func loadIfNeeded(days: Int? = nil, includeQuotas: Bool = false) {
        let storedDays = UserDefaults.standard.integer(forKey: PreferenceKey.aiUsageRangeDays)
        loadIfNeeded(
            query: .days(days ?? (storedDays == 0 ? 30 : storedDays)),
            includeQuotas: includeQuotas
        )
    }

    func loadIfNeeded(range: AIUsageRange, includeQuotas: Bool = false) {
        loadIfNeeded(query: .range(range), includeQuotas: includeQuotas)
    }

    func refresh(days: Int? = nil, includeQuotas: Bool = false) {
        let storedDays = UserDefaults.standard.integer(forKey: PreferenceKey.aiUsageRangeDays)
        refresh(
            query: .days(days ?? (storedDays == 0 ? 30 : storedDays)),
            includeQuotas: includeQuotas
        )
    }

    func refresh(range: AIUsageRange, includeQuotas: Bool = false) {
        refresh(query: .range(range), includeQuotas: includeQuotas)
    }

    func refreshCurrent(includeQuotas: Bool = false) {
        let stored = UserDefaults.standard.string(forKey: PreferenceKey.aiUsageRange)
        refresh(range: AIUsageRange(rawValue: stored ?? "") ?? .month, includeQuotas: includeQuotas)
    }

    private func loadIfNeeded(query: Query, includeQuotas: Bool) {
        guard completedQuery != query || (includeQuotas && summary.quotaScannedAt == nil) else { return }
        refresh(query: query, includeQuotas: includeQuotas)
    }

    private func refresh(query: Query, includeQuotas: Bool) {
        guard !isLoading else {
            let request = (query: query, includeQuotas: includeQuotas)
            if activeRequest?.query != request.query
                || (request.includeQuotas && activeRequest?.includeQuotas == false)
            {
                pendingRequest = request
            }
            return
        }

        activeRequest = (query, includeQuotas)
        isLoading = true
        Task {
            switch query {
            case .days(let days):
                summary = await scanner.scan(days: days, includeQuotas: includeQuotas)
            case .range(let range):
                summary = await scanner.scan(range: range, includeQuotas: includeQuotas)
            }
            completedQuery = query
            activeRequest = nil
            isLoading = false
            if let pendingRequest {
                self.pendingRequest = nil
                refresh(query: pendingRequest.query, includeQuotas: pendingRequest.includeQuotas)
            }
        }
    }
}
