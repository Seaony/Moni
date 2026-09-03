import SwiftUI

struct InstallerCleanerView: View {
    @Binding var mode: CleanerMode
    let refreshSystem: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let relativeDateFormatter = RelativeDateTimeFormatter()
    @State private var items: [InstallerCleanupItem] = []
    @State private var selectedPaths: Set<String> = []
    @State private var expandedSources: Set<InstallerSource> = []
    @State private var unreadableItemCount = 0
    @State private var isScanComplete = true
    @State private var isScanning = false
    @State private var scanProgress: CleanerScanProgress?
    @State private var isCleaning = false
    @State private var pendingPlan: InstallerCleanupPlan?
    @State private var cleanupMessage: String?

    var body: some View {
        VStack(spacing: 10) {
            header

            CleanerResultsCard {
                if isScanning {
                    if let scanProgress {
                        CleanerScanProgressView(progress: scanProgress)
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else if items.isEmpty, !isScanComplete {
                    ContentUnavailableView(
                        "Scan incomplete",
                        systemImage: "exclamationmark.triangle",
                        description: Text("The scan reached its time limit. Rescan to check the remaining locations.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if items.isEmpty {
                    ContentUnavailableView(
                        "No installer files",
                        systemImage: "shippingbox",
                        description: Text("No old macOS installers, disk images, packages, signed archives, or installer ZIP files were found.")
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
                            ForEach(InstallerSource.allCases, id: \.self) { source in
                                let sourceItems = items.filter { $0.source == source }
                                if !sourceItems.isEmpty {
                                    sourcePanel(source, items: sourceItems)
                                }
                            }
                        }
                        .padding(6)
                    }
                }
            }
        }
        .task {
            await scan()
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
            descriptionKey: "Select redundant installer files to review before moving them to Trash.",
            selectedSize: installerBytes(selectedSize),
            totalSize: installerBytes(totalSize),
            countTitleKey: "Sources",
            count: activeSourceCount.formatted(),
            status: scanStatus,
            statusColor: isScanning
                ? MoniPalette.blue
                : unreadableItemCount > 0 ? MoniPalette.orange : MoniPalette.foregroundSecondary,
            selectedItemCount: selectedPaths.count,
            isScanning: isScanning,
            isBusy: isCleaning,
            reviewSystemImage: "trash",
            breakdown: sourceBreakdown,
            onRescan: {
                Task { await scan() }
            },
            onReview: {
                Task { await prepareCleanup() }
            }
        )
    }

    private var sourceBreakdown: [CleanerBreakdownSegment] {
        let colors = [MoniPalette.blue, MoniPalette.green, MoniPalette.orange, MoniPalette.purple, MoniPalette.cyan, MoniPalette.yellow]
        return InstallerSource.allCases.enumerated().compactMap { index, source in
            let size = items.lazy.filter { $0.source == source }.reduce(UInt64(0)) { addingWithoutOverflow($0, $1.sizeBytes) }
            guard size > 0 else { return nil }
            return CleanerBreakdownSegment(
                id: source.rawValue,
                title: MoniLocalization.string(source.titleKey),
                value: size,
                color: colors[index % colors.count]
            )
        }
    }

    private var scanStatus: String {
        if isScanning { return MoniLocalization.string("Scanning…") }
        if unreadableItemCount > 0 {
            return MoniLocalization.format("%@ unreadable", unreadableItemCount.formatted())
        }
        return MoniLocalization.string("Ready")
    }

    private func sourcePanel(_ source: InstallerSource, items sourceItems: [InstallerCleanupItem]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    toggle(sourceItems)
                } label: {
                    Image(systemName: selectionSymbol(sourceItems))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(MoniPalette.blue)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)

                Button {
                    toggleExpansion(of: source)
                } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(MoniLocalization.string(source.titleKey))
                                .font(.system(size: 13.5, weight: .bold))
                            Text(MoniLocalization.format("%@ items", sourceItems.count.formatted()))
                                .font(.system(size: 10.5))
                                .foregroundStyle(MoniPalette.foregroundTertiary)
                        }
                        Spacer(minLength: 10)
                        Text(installerBytes(sourceItems.reduce(0) { addingWithoutOverflow($0, $1.sizeBytes) }))
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(MoniPalette.foregroundSecondary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(MoniPalette.foregroundTertiary)
                            .frame(width: 12)
                            .rotationEffect(.degrees(expandedSources.contains(source) ? 90 : 0))
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .frame(height: 48)

            if expandedSources.contains(source) {
                VStack(spacing: 0) {
                    Divider().padding(.leading, 48)

                    ForEach(sourceItems) { item in
                        Button {
                            toggle(item.path)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: selectedPaths.contains(item.path) ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 13.5, weight: .semibold))
                                    .foregroundStyle(selectedPaths.contains(item.path) ? MoniPalette.blue : MoniPalette.foregroundQuaternary)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.name)
                                        .font(.system(size: 12.5, weight: .medium))
                                        .lineLimit(1)
                                    HStack(spacing: 6) {
                                        Text(item.path)
                                            .font(.system(size: 10.5))
                                            .foregroundStyle(MoniPalette.foregroundTertiary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Text(item.kind.rawValue)
                                            .font(.system(size: 9.5, weight: .bold))
                                            .foregroundStyle(MoniPalette.purple)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(MoniPalette.purple.opacity(0.12))
                                            .clipShape(Capsule())
                                        Text(relativeDate(item.modifiedDate))
                                            .font(.system(size: 10))
                                            .foregroundStyle(MoniPalette.foregroundTertiary)
                                    }
                                }
                                Spacer(minLength: 10)
                                Text(installerBytes(item.sizeBytes))
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
        items.reduce(0) { addingWithoutOverflow($0, $1.sizeBytes) }
    }

    private var selectedSize: UInt64 {
        items.filter { selectedPaths.contains($0.path) }
            .reduce(0) { addingWithoutOverflow($0, $1.sizeBytes) }
    }

    private var activeSourceCount: Int {
        Set(items.map(\.source)).count
    }

    private var cleanupMessageBinding: Binding<Bool> {
        Binding(
            get: { cleanupMessage != nil },
            set: { if !$0 { cleanupMessage = nil } }
        )
    }

    private func selectionSymbol(_ sourceItems: [InstallerCleanupItem]) -> String {
        let selectedCount = sourceItems.count { selectedPaths.contains($0.path) }
        if selectedCount == sourceItems.count { return "checkmark.square.fill" }
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

    private func toggle(_ sourceItems: [InstallerCleanupItem]) {
        let paths = Set(sourceItems.map(\.path))
        if paths.isSubset(of: selectedPaths) {
            selectedPaths.subtract(paths)
        } else {
            selectedPaths.formUnion(paths)
        }
    }

    private func toggleExpansion(of source: InstallerSource) {
        withAnimation(reduceMotion ? nil : MoniMotion.disclosure) {
            if expandedSources.contains(source) {
                expandedSources.remove(source)
            } else {
                expandedSources.insert(source)
            }
        }
    }

    private func scan() async {
        isScanning = true
        scanProgress = nil
        let (progressUpdates, continuation) = AsyncStream<CleanerScanProgress>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let worker = Task.detached(priority: .utility) {
            let snapshot = await InstallerCleanupService.scan { progress in
                continuation.yield(progress)
            }
            continuation.finish()
            return snapshot
        }
        let snapshot = await withTaskCancellationHandler {
            for await progress in progressUpdates {
                scanProgress = progress
            }
            return await worker.value
        } onCancel: {
            worker.cancel()
        }
        guard !Task.isCancelled else {
            isScanning = false
            return
        }
        items = snapshot.items
        expandedSources = []
        unreadableItemCount = snapshot.unreadableItemCount
        isScanComplete = snapshot.isComplete
        selectedPaths = []
        scanProgress = nil
        isScanning = false
    }

    private func prepareCleanup() async {
        let selectedItems = items.filter { selectedPaths.contains($0.path) }
        let plan = await InstallerCleanupService.previewCleanup(items: selectedItems)
        if plan.cleanupPlan.candidates.isEmpty {
            cleanupMessage = MoniLocalization.string("No selected items can be cleaned.")
        } else {
            pendingPlan = plan
        }
    }

    private func execute(_ plan: InstallerCleanupPlan) async {
        isCleaning = true
        let result = await InstallerCleanupService.executeCleanup(plan)
        await scan()
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

    private func relativeDate(_ date: Date) -> String {
        let formatter = Self.relativeDateFormatter
        formatter.locale = MoniLocalization.currentLanguage.locale
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func addingWithoutOverflow(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : sum
    }
}

private func installerBytes(_ value: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
}
