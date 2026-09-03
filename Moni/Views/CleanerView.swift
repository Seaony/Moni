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

private enum CleanerMode: String, CaseIterable {
    case caches
    case projects
    case installers
    case trash
}

struct CleanerView: View {
    let refreshSystem: () -> Void
    @State private var mode = CleanerMode.caches

    var body: some View {
        VStack(spacing: 12) {
            Picker("", selection: $mode) {
                Text(MoniLocalization.string("Caches & Logs")).tag(CleanerMode.caches)
                Text(MoniLocalization.string("Project Artifacts")).tag(CleanerMode.projects)
                Text(MoniLocalization.string("Installers")).tag(CleanerMode.installers)
                Text(MoniLocalization.string("Trash")).tag(CleanerMode.trash)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 520)

            switch mode {
            case .caches:
                CacheCleanerView(refreshSystem: refreshSystem)
            case .projects:
                ProjectArtifactCleanerView(refreshSystem: refreshSystem)
            case .installers:
                InstallerCleanerView(refreshSystem: refreshSystem)
            case .trash:
                TrashCleanerView(refreshSystem: refreshSystem)
            }
        }
    }
}

private struct CacheCleanerView: View {
    let refreshSystem: () -> Void
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
        VStack(spacing: 12) {
            header
            summary

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
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 10) {
                        ForEach(CacheCleanupCategory.allCases, id: \.self) { category in
                            let categoryItems = items.filter { $0.category == category }
                            if !categoryItems.isEmpty {
                                categoryPanel(category, items: categoryItems)
                            }
                        }
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
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Cleaner")
                    .font(.system(size: 20, weight: .bold))
                Text("Review rebuildable user caches and logs before moving them to Trash.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(MoniPalette.foregroundTertiary)
            }

            Spacer(minLength: 12)

            Button {
                scanner.start(force: true, selectAll: true)
            } label: {
                Label(MoniLocalization.string("Rescan"), systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(scanner.isScanning || isCleaning)

            Button {
                Task { await prepareCleanup() }
            } label: {
                Label(
                    MoniLocalization.format("Review %@ items", selectedPaths.count.formatted()),
                    systemImage: "trash"
                )
            }
            .buttonStyle(.borderedProminent)
            .tint(MoniPalette.red)
            .disabled(selectedPaths.isEmpty || scanner.isScanning || isCleaning)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(MoniPalette.card)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(MoniPalette.panelLine, lineWidth: 1)
        }
    }

    private var summary: some View {
        HStack(spacing: 10) {
            summaryCard("Reclaimable", cleanupBytes(totalSize), color: MoniPalette.green)
            summaryCard("Selected", cleanupBytes(selectedSize), color: MoniPalette.blue)
            summaryCard("Categories", activeCategoryCount.formatted(), color: MoniPalette.orange)
            if unreadableItemCount > 0 {
                summaryCard("Unreadable", unreadableItemCount.formatted(), color: MoniPalette.red)
            }
        }
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

    private func summaryCard(_ title: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(MoniLocalization.string(title))
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(MoniPalette.foregroundTertiary)
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(color)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MoniPalette.insetSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
                        Image(systemName: expandedCategories.contains(category) ? "chevron.down" : "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(MoniPalette.foregroundTertiary)
                            .frame(width: 12)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            if expandedCategories.contains(category) {
                Divider().padding(.horizontal, 12)

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
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(selectedPaths.contains(item.path) ? MoniPalette.selection.opacity(0.55) : Color.clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .background(MoniPalette.card)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(MoniPalette.panelLine, lineWidth: 1)
        }
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
        if expandedCategories.contains(category) {
            expandedCategories.remove(category)
        } else {
            expandedCategories.insert(category)
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
