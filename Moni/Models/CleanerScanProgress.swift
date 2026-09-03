import Foundation

nonisolated enum CleanerScanTaskLabel: Sendable {
    case localized(String)
    case plain(String)
}

nonisolated struct CleanerScanProgress: Sendable {
    let titleKey: String
    let stepNumber: Int
    let stepCount: Int
    let completedTaskCount: Int
    let totalTaskCount: Int
    let currentTasks: [CleanerScanTaskLabel]
    let discoveredItemCount: Int
    let discoveredItemLabelKey: String
    let startedAt: Date
    let timeLimit: TimeInterval?

    var fractionCompleted: Double? {
        guard totalTaskCount > 0 else { return nil }
        return min(1, Double(completedTaskCount) / Double(totalTaskCount))
    }
}
