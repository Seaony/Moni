import SwiftUI

struct CleanerScanProgressView: View {
    let progress: CleanerScanProgress

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(MoniLocalization.string(progress.titleKey))
                            .font(.system(size: 15, weight: .semibold))
                        Text(MoniLocalization.format(
                            "Stage %@ of %@",
                            progress.stepNumber.formatted(),
                            progress.stepCount.formatted()
                        ))
                        .font(.system(size: 11.5))
                        .foregroundStyle(MoniPalette.foregroundTertiary)
                    }
                }

                if let fractionCompleted = progress.fractionCompleted {
                    ProgressView(value: fractionCompleted)
                        .tint(MoniPalette.green)
                    HStack {
                        Text(MoniLocalization.format(
                            "%@ of %@ checks complete",
                            progress.completedTaskCount.formatted(),
                            progress.totalTaskCount.formatted()
                        ))
                        Spacer()
                        Text(fractionCompleted.formatted(.percent.precision(.fractionLength(0))))
                    }
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(MoniPalette.foregroundSecondary)
                }

                if !progress.currentTasks.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 5) {
                        Text(MoniLocalization.string("Scanning now"))
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(MoniPalette.foregroundTertiary)
                            .textCase(.uppercase)
                        Text(progress.currentTasks.map(taskTitle).joined(separator: "  ·  "))
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(MoniPalette.foregroundSecondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }

                HStack(spacing: 16) {
                    Label(
                        MoniLocalization.format(
                            progress.discoveredItemLabelKey,
                            progress.discoveredItemCount.formatted()
                        ),
                        systemImage: "doc.text.magnifyingglass"
                    )
                    Label(elapsedLabel(at: context.date), systemImage: "clock")
                }
                .font(.system(size: 11.5))
                .foregroundStyle(MoniPalette.foregroundTertiary)
            }
            .padding(18)
            .frame(maxWidth: 470)
            .background(MoniPalette.card)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(MoniPalette.panelLine, lineWidth: 1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func taskTitle(_ task: CleanerScanTaskLabel) -> String {
        switch task {
        case let .localized(key): MoniLocalization.string(key)
        case let .plain(value): value
        }
    }

    private func elapsedLabel(at date: Date) -> String {
        let elapsed = duration(date.timeIntervalSince(progress.startedAt))
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
