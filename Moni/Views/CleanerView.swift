import Combine
import SwiftUI

@MainActor
final class CacheCleanupScanner: ObservableObject {
    @Published private(set) var snapshot: CacheCleanupSnapshot?
    @Published private(set) var isScanning = false
    @Published private(set) var progress: CacheCleanupScanProgress?
    @Published private(set) var completedScanID = 0
    @Published private(set) var completedScanSelectAll = true

    private var worker: Task<CacheCleanupSnapshot, Never>?

    func start(force: Bool = false, selectAll: Bool = true) {
        guard worker == nil else { return }
        guard force || snapshot == nil else { return }

        isScanning = true
        progress = nil
        let (progressUpdates, continuation) = AsyncStream<CacheCleanupScanProgress>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let worker = Task.detached(priority: .utility) {
            let snapshot = await CacheCleanupService.scan { progress in
                continuation.yield(progress)
            }
            continuation.finish()
            return snapshot
        }
        self.worker = worker

        Task { [weak self] in
            for await progress in progressUpdates {
                self?.progress = progress
            }
            let snapshot = await worker.value
            guard let self, self.worker != nil else { return }
            self.snapshot = snapshot
            self.completedScanSelectAll = selectAll
            self.worker = nil
            self.isScanning = false
            self.completedScanID += 1
        }
    }
}

enum CleanerMode: String, CaseIterable {
    case caches
    case projects
    case installers
    case trash

    var titleKey: String {
        switch self {
        case .caches: "Caches & Logs"
        case .projects: "Project Artifacts"
        case .installers: "Installers"
        case .trash: "Trash"
        }
    }
}

struct CleanerBreakdownSegment: Identifiable {
    let id: String
    let title: String
    let value: UInt64
    let color: Color
}

struct CleanerResultsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(MoniPalette.card)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(MoniPalette.panelLine, lineWidth: 1)
        }
    }
}

struct CleanerSelectionHeader: View {
    let symbol: String
    let selectedCount: Int
    let totalCount: Int
    let onToggleAll: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onToggleAll) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(MoniPalette.blue)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)

            Button(action: onToggleAll) {
                Text(MoniLocalization.format(
                    "%@ of %@ selected",
                    selectedCount.formatted(),
                    totalCount.formatted()
                ))
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(MoniPalette.foregroundTertiary)
            }
            .buttonStyle(.plain)

            Spacer()

            Text(MoniLocalization.string("Items"))
                .frame(width: 132, alignment: .leading)
            Text(MoniLocalization.string("Size"))
                .frame(width: 86, alignment: .trailing)
            Color.clear.frame(width: 26)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(MoniPalette.foregroundQuaternary)
        .padding(.horizontal, 16)
        .frame(height: 35)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(MoniPalette.panelLine)
                .frame(height: 1)
        }
    }
}

struct CleanerPageHeader: View {
    @Binding var mode: CleanerMode
    let descriptionKey: String
    let selectedSize: String
    let totalSize: String
    let countTitleKey: String
    let count: String
    let status: String
    let statusColor: Color
    let selectedItemCount: Int
    let isScanning: Bool
    let isBusy: Bool
    let reviewSystemImage: String
    let breakdown: [CleanerBreakdownSegment]
    let onRescan: () -> Void
    let onReview: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Cleaner")
                        .font(.system(size: 17, weight: .bold))
                    Text(MoniLocalization.string(descriptionKey))
                        .font(.system(size: 12.5))
                        .foregroundStyle(MoniPalette.foregroundTertiary)
                }

                Spacer(minLength: 12)

                HStack(spacing: 8) {
                    Button(action: onRescan) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 13, weight: .medium))
                                .rotationEffect(.degrees(isScanning ? 360 : 0))
                                .animation(
                                    isScanning
                                        ? .linear(duration: 0.8).repeatForever(autoreverses: false)
                                        : nil,
                                    value: isScanning
                                )
                            Text(MoniLocalization.string(isScanning ? "Scanning…" : "Rescan"))
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(
                            isScanning || isBusy
                                ? MoniPalette.disabledActionForeground
                                : MoniPalette.secondaryActionForeground
                        )
                        .padding(.horizontal, 13)
                        .frame(height: 32)
                        .background(MoniPalette.secondaryAction)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(MoniPressButtonStyle(scale: 0.98))
                    .disabled(isScanning || isBusy)

                    Button(action: onReview) {
                        HStack(spacing: 7) {
                            Image(systemName: reviewSystemImage)
                                .font(.system(size: 13, weight: .medium))
                            Text(reviewButtonTitle)
                                .font(.system(size: 13, weight: .bold))
                        }
                        .foregroundStyle(canReview ? Color.white : MoniPalette.disabledActionForeground)
                        .padding(.horizontal, 15)
                        .frame(height: 32)
                        .background(canReview ? MoniPalette.red : MoniPalette.secondaryAction)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(MoniPressButtonStyle(scale: 0.98))
                    .disabled(!canReview)
                }
            }

            HStack(spacing: 16) {
                HStack(spacing: 2) {
                    ForEach(CleanerMode.allCases, id: \.self) { candidate in
                        Button {
                            mode = candidate
                        } label: {
                            HStack(spacing: 6) {
                                Text(MoniLocalization.string(candidate.titleKey))
                                    .lineLimit(1)
                                Text(candidate == mode ? count : "—")
                                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(
                                        candidate == mode
                                            ? Color.white.opacity(0.22)
                                            : MoniPalette.track
                                    )
                                    .clipShape(Capsule())
                            }
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(candidate == mode ? Color.white : MoniPalette.foregroundTertiary)
                            .padding(.horizontal, 12)
                            .frame(height: 28)
                            .background(candidate == mode ? MoniPalette.blue : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(MoniPressButtonStyle(scale: 0.99))
                    }
                }
                .padding(3)
                .background(MoniPalette.control)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

                Spacer(minLength: 4)

                HStack(spacing: 22) {
                    cleanerMetric("Selected", selectedSize, color: MoniPalette.green)
                    cleanerMetric("This page", totalSize, color: MoniPalette.foreground)
                    cleanerMetric(countTitleKey, count, color: MoniPalette.foreground)
                    cleanerMetric("Last scan", status, color: statusColor)
                }
            }

            if !breakdown.isEmpty {
                breakdownBar
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(MoniPalette.card)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(MoniPalette.panelLine, lineWidth: 1)
        }
    }

    private func cleanerMetric(_ titleKey: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(MoniLocalization.string(titleKey))
                .font(.system(size: 11.5))
                .foregroundStyle(MoniPalette.foregroundTertiary)
            Text(value)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }

    private var canReview: Bool {
        selectedItemCount > 0 && !isScanning && !isBusy
    }

    private var reviewButtonTitle: String {
        guard canReview else {
            return MoniLocalization.string("No items selected")
        }
        return MoniLocalization.format(
            mode == .trash ? "Delete Permanently · %@" : "Move to Trash · %@",
            selectedSize
        )
    }

    private var breakdownBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geometry in
                let spacing = CGFloat(max(0, breakdown.count - 1)) * 1.5
                let availableWidth = max(0, geometry.size.width - spacing)
                let total = max(1, breakdown.reduce(UInt64(0)) { $0 + $1.value })
                HStack(spacing: 1.5) {
                    ForEach(breakdown) { segment in
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(segment.color)
                            .frame(width: max(3, availableWidth * CGFloat(segment.value) / CGFloat(total)))
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 9)

            HStack(spacing: 16) {
                ForEach(breakdown.prefix(6)) { segment in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(segment.color)
                            .frame(width: 7, height: 7)
                        Text(segment.title)
                            .lineLimit(1)
                        Text(cleanupBytes(segment.value))
                            .fontWeight(.semibold)
                            .foregroundStyle(MoniPalette.foregroundSecondary)
                            .lineLimit(1)
                    }
                    .font(.system(size: 10.5))
                    .foregroundStyle(MoniPalette.foregroundTertiary)
                }
            }
        }
    }
}

struct CleanerView: View {
    let refreshSystem: () -> Void
    @State private var mode = CleanerMode.caches

    var body: some View {
        Group {
            switch mode {
            case .caches:
                CacheCleanerView(mode: $mode, refreshSystem: refreshSystem)
            case .projects:
                ProjectArtifactCleanerView(mode: $mode, refreshSystem: refreshSystem)
            case .installers:
                InstallerCleanerView(mode: $mode, refreshSystem: refreshSystem)
            case .trash:
                TrashCleanerView(mode: $mode, refreshSystem: refreshSystem)
            }
        }
        .padding(.horizontal, -2)
    }
}

private struct CacheCleanerView: View {
    @Binding var mode: CleanerMode
    let refreshSystem: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var scanner: CacheCleanupScanner
    @State private var items: [CacheCleanupItem] = []
    @State private var selectedPaths: Set<String> = []
    @State private var expandedCategories: Set<CacheCleanupCategory> = []
    @State private var unreadableItemCount = 0
    @State private var isScanComplete = true
    @State private var isCleaning = false
    @State private var pendingPlan: CacheCleanupPlan?
    @State private var cleanupMessage: String?

    var body: some View {
        VStack(spacing: 10) {
            header

            CleanerResultsCard {
                if scanner.isScanning {
                    scanProgressView
                } else if items.isEmpty, !isScanComplete {
                    ContentUnavailableView(
                        "Scan incomplete",
                        systemImage: "exclamationmark.triangle",
                        description: Text("The scan reached its time limit. Rescan to check the remaining locations.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if items.isEmpty {
                    ContentUnavailableView(
                        "No cleanable items",
                        systemImage: "sparkles",
                        description: Text("No cleanable cache or log files were found.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    CleanerSelectionHeader(
                        symbol: selectionSymbol,
                        selectedCount: selectedPaths.count,
                        totalCount: items.count,
                        onToggleAll: toggleAll
                    )
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(spacing: 0) {
                            ForEach(CacheCleanupCategory.allCases, id: \.self) { category in
                                let categoryItems = items.filter { $0.category == category }
                                if !categoryItems.isEmpty {
                                    categoryPanel(category, items: categoryItems)
                                }
                            }
                        }
                        .padding(6)
                    }
                }
            }
        }
        .onAppear {
            if let snapshot = scanner.snapshot {
                apply(snapshot, selectAll: scanner.completedScanSelectAll)
            }
            scanner.start()
        }
        .onChange(of: scanner.completedScanID) { _, _ in
            guard let snapshot = scanner.snapshot else { return }
            apply(snapshot, selectAll: scanner.completedScanSelectAll)
        }
        .sheet(item: $pendingPlan) { plan in
            CleanupConfirmationView(
                plan: plan.cleanupPlan,
                onCancel: { pendingPlan = nil },
                onConfirm: {
                    pendingPlan = nil
                    Task { await execute(plan) }
                }
            )
        }
        .alert("Cleanup result", isPresented: cleanupMessageBinding) {
            Button("OK") { cleanupMessage = nil }
        } message: {
            Text(cleanupMessage ?? "")
        }
    }

    private var header: some View {
        CleanerPageHeader(
            mode: $mode,
            descriptionKey: "Review rebuildable user caches and logs before moving them to Trash.",
            selectedSize: cleanupBytes(selectedSize),
            totalSize: cleanupBytes(totalSize),
            countTitleKey: "Categories",
            count: activeCategoryCount.formatted(),
            status: scanStatus,
            statusColor: scanner.isScanning
                ? MoniPalette.blue
                : unreadableItemCount > 0 ? MoniPalette.orange : MoniPalette.foregroundSecondary,
            selectedItemCount: selectedPaths.count,
            isScanning: scanner.isScanning,
            isBusy: isCleaning,
            reviewSystemImage: "trash",
            breakdown: categoryBreakdown,
            onRescan: {
                scanner.start(force: true, selectAll: true)
            },
            onReview: {
                Task { await prepareCleanup() }
            }
        )
    }

    private var scanProgressView: some View {
        Group {
            if let progress = scanner.progress {
                CleanerScanProgressView(progress: CleanerScanProgress(
                    titleKey: progress.phase.titleKey,
                    stepNumber: progress.phase.stepNumber,
                    stepCount: CacheCleanupScanPhase.stepCount,
                    completedTaskCount: progress.completedTaskCount,
                    totalTaskCount: progress.totalTaskCount,
                    currentTasks: progress.activeTaskTitleKeys.map { .localized($0) },
                    discoveredItemCount: progress.discoveredItemCount,
                    discoveredItemLabelKey: "%@ candidates found",
                    startedAt: progress.startedAt,
                    timeLimit: progress.timeLimit
                ))
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var categoryBreakdown: [CleanerBreakdownSegment] {
        let colors = [MoniPalette.blue, MoniPalette.green, MoniPalette.orange, MoniPalette.purple, MoniPalette.cyan, MoniPalette.yellow]
        return CacheCleanupCategory.allCases.enumerated().compactMap { index, category in
            let size = items.lazy.filter { $0.category == category }.reduce(UInt64(0)) { $0 + $1.sizeBytes }
            guard size > 0 else { return nil }
            return CleanerBreakdownSegment(
                id: category.rawValue,
                title: MoniLocalization.string(category.titleKey),
                value: size,
                color: colors[index % colors.count]
            )
        }
    }

    private var scanStatus: String {
        if scanner.isScanning { return MoniLocalization.string("Scanning…") }
        if unreadableItemCount > 0 {
            return MoniLocalization.format("%@ unreadable", unreadableItemCount.formatted())
        }
        return MoniLocalization.string("Ready")
    }

    private func categoryPanel(_ category: CacheCleanupCategory, items categoryItems: [CacheCleanupItem]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    toggle(categoryItems)
                } label: {
                    Image(systemName: categorySelectionSymbol(categoryItems))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(MoniPalette.blue)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)

                Button {
                    toggleExpansion(of: category)
                } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(MoniLocalization.string(category.titleKey))
                                .font(.system(size: 13.5, weight: .bold))
                            Text(MoniLocalization.format("%@ items", categoryItems.count.formatted()))
                                .font(.system(size: 10.5))
                                .foregroundStyle(MoniPalette.foregroundTertiary)
                        }
                        Spacer(minLength: 10)
                        Text(cleanupBytes(categoryItems.reduce(UInt64(0)) { $0 + $1.sizeBytes }))
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(MoniPalette.foregroundSecondary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(MoniPalette.foregroundTertiary)
                            .frame(width: 12)
                            .rotationEffect(.degrees(expandedCategories.contains(category) ? 90 : 0))
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .frame(height: 48)

            if expandedCategories.contains(category) {
                VStack(spacing: 0) {
                    Divider().padding(.leading, 48)

                    ForEach(categoryItems) { item in
                        Button {
                            toggle(item.path)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: selectedPaths.contains(item.path) ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 13.5, weight: .semibold))
                                    .foregroundStyle(selectedPaths.contains(item.path) ? MoniPalette.blue : MoniPalette.foregroundQuaternary)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(URL(fileURLWithPath: item.path).lastPathComponent)
                                        .font(.system(size: 12.5, weight: .medium))
                                        .lineLimit(1)
                                    Text(URL(fileURLWithPath: item.path).deletingLastPathComponent().path)
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(MoniPalette.foregroundTertiary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer(minLength: 10)
                                Text(cleanupBytes(item.sizeBytes))
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .foregroundStyle(MoniPalette.foregroundSecondary)
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 44)
                            .background(selectedPaths.contains(item.path) ? MoniPalette.selection.opacity(0.55) : Color.clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .transition(reduceMotion ? .identity : MoniMotion.disclosureTransition)
            }
        }
        .contentShape(Rectangle())
    }

    private var totalSize: UInt64 {
        items.reduce(0) { $0 + $1.sizeBytes }
    }

    private var selectedSize: UInt64 {
        items.reduce(0) { total, item in
            selectedPaths.contains(item.path) ? total + item.sizeBytes : total
        }
    }

    private var activeCategoryCount: Int {
        Set(items.map(\.category)).count
    }

    private var cleanupMessageBinding: Binding<Bool> {
        Binding(
            get: { cleanupMessage != nil },
            set: { if !$0 { cleanupMessage = nil } }
        )
    }

    private func categorySelectionSymbol(_ categoryItems: [CacheCleanupItem]) -> String {
        let selectedCount = categoryItems.count { selectedPaths.contains($0.path) }
        if selectedCount == categoryItems.count { return "checkmark.square.fill" }
        if selectedCount > 0 { return "minus.square.fill" }
        return "square"
    }

    private var selectionSymbol: String {
        if selectedPaths.count == items.count { return "checkmark.square.fill" }
        if !selectedPaths.isEmpty { return "minus.square.fill" }
        return "square"
    }

    private func toggleAll() {
        if selectedPaths.count == items.count {
            selectedPaths.removeAll()
        } else {
            selectedPaths = Set(items.map(\.path))
        }
    }

    private func toggle(_ path: String) {
        if selectedPaths.contains(path) {
            selectedPaths.remove(path)
        } else {
            selectedPaths.insert(path)
        }
    }

    private func toggle(_ categoryItems: [CacheCleanupItem]) {
        let paths = Set(categoryItems.map(\.path))
        if paths.isSubset(of: selectedPaths) {
            selectedPaths.subtract(paths)
        } else {
            selectedPaths.formUnion(paths)
        }
    }

    private func toggleExpansion(of category: CacheCleanupCategory) {
        withAnimation(reduceMotion ? nil : MoniMotion.disclosure) {
            if expandedCategories.contains(category) {
                expandedCategories.remove(category)
            } else {
                expandedCategories.insert(category)
            }
        }
    }

    private func apply(_ snapshot: CacheCleanupSnapshot, selectAll: Bool) {
        items = snapshot.items
        expandedCategories = []
        unreadableItemCount = snapshot.unreadableItemCount
        isScanComplete = snapshot.isComplete
        selectedPaths = selectAll ? Set(snapshot.items.map(\.path)) : []
    }

    private func prepareCleanup() async {
        let plan = await CacheCleanupService.previewCleanup(
            items: items.filter { selectedPaths.contains($0.path) }
        )
        if plan.cleanupPlan.candidates.isEmpty {
            cleanupMessage = MoniLocalization.string("No selected items can be cleaned.")
        } else {
            pendingPlan = plan
        }
    }

    private func execute(_ plan: CacheCleanupPlan) async {
        isCleaning = true
        let result = await CacheCleanupService.executeCleanup(plan)
        scanner.start(force: true, selectAll: false)
        isCleaning = false
        refreshSystem()

        var parts: [String] = []
        if !result.trashedPaths.isEmpty {
            parts.append(MoniLocalization.format("Moved %@ items to Trash.", result.trashedPaths.count.formatted()))
        }
        if !result.rejectedItems.isEmpty {
            parts.append(MoniLocalization.format("%@ items were protected or changed.", result.rejectedItems.count.formatted()))
        }
        if !result.failedPaths.isEmpty {
            parts.append(MoniLocalization.format("%@ items could not be moved.", result.failedPaths.count.formatted()))
        }
        cleanupMessage = parts.joined(separator: " ")
    }
}

private func cleanupBytes(_ value: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
}
