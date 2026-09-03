import SwiftUI

struct ProjectArtifactCleanerView: View {
    let refreshSystem: () -> Void
    @State private var items: [ProjectArtifactItem] = []
    @State private var selectedPaths: Set<String> = []
    @State private var expandedProjectPaths: Set<String> = []
    @State private var failedRootCount = 0
    @State private var isScanning = false
    @State private var scanProgress: CleanerScanProgress?
    @State private var isCleaning = false
    @State private var pendingPlan: ProjectArtifactCleanupPlan?
    @State private var cleanupMessage: String?

    var body: some View {
        VStack(spacing: 12) {
            header
            summary

            if isScanning {
                if let scanProgress {
                    CleanerScanProgressView(progress: scanProgress)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if items.isEmpty, failedRootCount > 0 {
                ContentUnavailableView(
                    "Scan incomplete",
                    systemImage: "exclamationmark.triangle",
                    description: Text("Some project locations could not be fully scanned. Rescan to try again.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                ContentUnavailableView(
                    "No project artifacts",
                    systemImage: "hammer",
                    description: Text("No rebuildable project dependencies or build output were found.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 10) {
                        ForEach(projectGroups, id: \.path) { group in
                            projectPanel(path: group.path, items: group.items)
                        }
                    }
                }
            }
        }
        .task {
            await scan(useDefaultSelection: true)
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
                Text("Project Artifacts")
                    .font(.system(size: 20, weight: .bold))
                Text("Review rebuildable dependencies and build output before moving them to Trash.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(MoniPalette.foregroundTertiary)
            }

            Spacer(minLength: 12)

            Button {
                Task { await scan(useDefaultSelection: true) }
            } label: {
                Label(MoniLocalization.string("Rescan"), systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(isScanning || isCleaning)

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
            .disabled(selectedPaths.isEmpty || isScanning || isCleaning)
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
            summaryCard("Reclaimable", artifactBytes(totalKnownSize), color: MoniPalette.green)
            summaryCard("Selected", artifactBytes(selectedKnownSize), color: MoniPalette.blue)
            summaryCard("Projects", projectGroups.count.formatted(), color: MoniPalette.orange)
            if unknownSizeCount > 0 {
                summaryCard("Unknown size", unknownSizeCount.formatted(), color: MoniPalette.yellow)
            }
            if failedRootCount > 0 {
                summaryCard("Unavailable roots", failedRootCount.formatted(), color: MoniPalette.red)
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

    private func projectPanel(path: String, items projectItems: [ProjectArtifactItem]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    toggle(projectItems)
                } label: {
                    Image(systemName: selectionSymbol(projectItems))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(MoniPalette.blue)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)

                Button {
                    toggleExpansion(of: path)
                } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(URL(fileURLWithPath: path).lastPathComponent)
                                .font(.system(size: 13.5, weight: .bold))
                                .lineLimit(1)
                            Text(path)
                                .font(.system(size: 10.5))
                                .foregroundStyle(MoniPalette.foregroundTertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 10)
                        Text(groupSizeLabel(projectItems))
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(MoniPalette.foregroundSecondary)
                        Image(systemName: expandedProjectPaths.contains(path) ? "chevron.down" : "chevron.right")
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

            if expandedProjectPaths.contains(path) {
                Divider().padding(.horizontal, 12)

                ForEach(projectItems) { item in
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
                                    activityLabel(item)
                                }
                            }
                            Spacer(minLength: 10)
                            Text(item.sizeBytes.map(artifactBytes) ?? MoniLocalization.string("Unknown"))
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

    private func activityLabel(_ item: ProjectArtifactItem) -> some View {
        let title: String
        let color: Color
        if item.isCloudSynced {
            title = "Cloud synced"
            color = MoniPalette.cyan
        } else {
            switch item.activity {
            case .old:
                title = "Inactive 7+ days"
                color = MoniPalette.green
            case .recent:
                title = "Recently active"
                color = MoniPalette.orange
            case .uncertain:
                title = "Needs review"
                color = MoniPalette.yellow
            }
        }
        return Text(MoniLocalization.string(title))
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }

    private var projectGroups: [(path: String, items: [ProjectArtifactItem])] {
        Dictionary(grouping: items, by: \.projectRootPath)
            .map { (path: $0.key, items: $0.value) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private var totalKnownSize: UInt64 {
        items.compactMap(\.sizeBytes).reduce(0, addingWithoutOverflow)
    }

    private var selectedKnownSize: UInt64 {
        items.filter { selectedPaths.contains($0.path) }
            .compactMap(\.sizeBytes)
            .reduce(0, addingWithoutOverflow)
    }

    private var unknownSizeCount: Int {
        items.count { $0.sizeBytes == nil }
    }

    private var cleanupMessageBinding: Binding<Bool> {
        Binding(
            get: { cleanupMessage != nil },
            set: { if !$0 { cleanupMessage = nil } }
        )
    }

    private func selectionSymbol(_ projectItems: [ProjectArtifactItem]) -> String {
        let selectedCount = projectItems.count { selectedPaths.contains($0.path) }
        if selectedCount == projectItems.count { return "checkmark.square.fill" }
        if selectedCount > 0 { return "minus.square.fill" }
        return "square"
    }

    private func groupSizeLabel(_ projectItems: [ProjectArtifactItem]) -> String {
        let knownSize = projectItems.compactMap(\.sizeBytes).reduce(0, addingWithoutOverflow)
        return projectItems.contains { $0.sizeBytes == nil }
            ? MoniLocalization.format("%@ + unknown", artifactBytes(knownSize))
            : artifactBytes(knownSize)
    }

    private func toggle(_ path: String) {
        if selectedPaths.contains(path) {
            selectedPaths.remove(path)
        } else {
            selectedPaths.insert(path)
        }
    }

    private func toggle(_ projectItems: [ProjectArtifactItem]) {
        let paths = Set(projectItems.map(\.path))
        if paths.isSubset(of: selectedPaths) {
            selectedPaths.subtract(paths)
        } else {
            selectedPaths.formUnion(paths)
        }
    }

    private func toggleExpansion(of path: String) {
        if expandedProjectPaths.contains(path) {
            expandedProjectPaths.remove(path)
        } else {
            expandedProjectPaths.insert(path)
        }
    }

    private func scan(useDefaultSelection: Bool) async {
        isScanning = true
        scanProgress = nil
        let (progressUpdates, continuation) = AsyncStream<CleanerScanProgress>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let worker = Task.detached(priority: .utility) {
            let snapshot = await ProjectArtifactService.scan { progress in
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
        expandedProjectPaths = []
        failedRootCount = snapshot.failedRootPaths.count
        selectedPaths = useDefaultSelection
            ? Set(snapshot.items.filter(\.isSelectedByDefault).map(\.path))
            : []
        scanProgress = nil
        isScanning = false
    }

    private func prepareCleanup() async {
        let selectedItems = items.filter { selectedPaths.contains($0.path) }
        let plan = await ProjectArtifactService.previewCleanup(items: selectedItems)
        if plan.cleanupPlan.candidates.isEmpty {
            cleanupMessage = MoniLocalization.string("No selected items can be cleaned.")
        } else {
            pendingPlan = plan
        }
    }

    private func execute(_ plan: ProjectArtifactCleanupPlan) async {
        isCleaning = true
        let result = await ProjectArtifactService.executeCleanup(plan)
        await scan(useDefaultSelection: false)
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

    private func addingWithoutOverflow(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : sum
    }
}

private func artifactBytes(_ value: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
}
