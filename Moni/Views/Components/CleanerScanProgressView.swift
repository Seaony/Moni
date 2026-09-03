import SwiftUI

struct CleanerScanProgressView: View {
    let progress: CleanerScanProgress

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text(MoniLocalization.string(progress.titleKey))
                        .font(.system(size: 12.5, weight: .semibold))
                    Text(currentTaskText)
                        .font(.system(size: 11.5))
                        .foregroundStyle(MoniPalette.foregroundQuaternary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(progressLabel)
                        .font(.system(size: 11.5, weight: .bold, design: .rounded))
                        .foregroundStyle(MoniPalette.blue)
                }

                if let fractionCompleted = progress.fractionCompleted {
                    ProgressView(value: fractionCompleted)
                        .tint(MoniPalette.blue)
                        .controlSize(.small)
                    HStack {
                        Text(MoniLocalization.format(
                            "%@ of %@ checks complete",
                            progress.completedTaskCount.formatted(),
                            progress.totalTaskCount.formatted()
                        ))
                        Spacer()
                        Text(elapsedLabel(at: context.date))
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(MoniPalette.foregroundTertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(MoniPalette.panelLine)
                    .frame(height: 1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var currentTaskText: String {
        guard !progress.currentTasks.isEmpty else {
            return MoniLocalization.format(
                progress.discoveredItemLabelKey,
                progress.discoveredItemCount.formatted()
            )
        }
        return progress.currentTasks.map(taskTitle).joined(separator: " · ")
    }

    private var progressLabel: String {
        guard let fractionCompleted = progress.fractionCompleted else {
            return MoniLocalization.format(
                "Stage %@ of %@",
                progress.stepNumber.formatted(),
                progress.stepCount.formatted()
            )
        }
        return fractionCompleted.formatted(.percent.precision(.fractionLength(0)))
    }

    private func taskTitle(_ task: CleanerScanTaskLabel) -> String {
        switch task {
        case let .localized(key): MoniLocalization.string(key)
        case let .plain(value): value
        }
    }

    private func elapsedLabel(at date: Date) -> String {
        let elapsedInterval = max(0, date.timeIntervalSince(progress.startedAt))
        let elapsed = duration(elapsedInterval)
        if let fraction = progress.fractionCompleted,
           fraction > 0.01,
           fraction < 1 {
            let remaining = duration(elapsedInterval / fraction * (1 - fraction))
            return MoniLocalization.format("Elapsed %@ · about %@ remaining", elapsed, remaining)
        }
        guard let timeLimit = progress.timeLimit else {
            return MoniLocalization.format("Elapsed %@", elapsed)
        }
        return MoniLocalization.format(
            "Elapsed %@ · %@ scan budget",
            elapsed,
            duration(timeLimit)
        )
    }

    private func duration(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded(.down)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
