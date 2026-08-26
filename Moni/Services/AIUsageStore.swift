import Combine
import Foundation

@MainActor
final class AIUsageStore: ObservableObject {
    @Published private(set) var summary = AIUsageSummary()
    @Published private(set) var isLoading = false

    private let scanner = AIUsageScanner()
    private var activeDays: Int?
    private var pendingDays: Int?

    func loadIfNeeded(days: Int? = nil) {
        guard summary.scannedAt == nil else { return }
        refresh(days: days)
    }

    func refresh(days: Int? = nil) {
        let storedDays = UserDefaults.standard.integer(forKey: PreferenceKey.aiUsageRangeDays)
        let rangeDays = days ?? (storedDays == 0 ? 30 : storedDays)
        guard !isLoading else {
            if activeDays != rangeDays {
                pendingDays = rangeDays
            }
            return
        }
        activeDays = rangeDays
        isLoading = true
        Task {
            summary = await scanner.scan(days: rangeDays)
            activeDays = nil
            isLoading = false
            if let pendingDays {
                self.pendingDays = nil
                refresh(days: pendingDays)
            }
        }
    }
}
