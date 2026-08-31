import SwiftUI

struct InstallerCleanerView: View {
    @EnvironmentObject private var monitor: SystemMonitor
    @State private var items: [InstallerCleanupItem] = []
    @State private var selectedPaths: Set<String> = []
    @State private var unreadableItemCount = 0
    @State private var isScanning = false
    @State private var isCleaning = false
    @State private var pendingPlan: InstallerCleanupPlan?
    @State private var cleanupMessage: String?

    var body: some View {
        VStack(spacing: 12) {
            header
            summary

            if isScanning {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Scanning for installer files…")
                        .font(.system(size: 12.5))
                        .foregroundStyle(MoniPalette.foregroundTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                ContentUnavailableView(
                    "No installer files",
                    systemImage: "shippingbox",
                    description: Text("No disk images, packages, signed archives, or installer ZIP files were found.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 10) {
                        ForEach(InstallerSource.allCases, id: \.self) { source in
                            let sourceItems = items.filter { $0.source == source }
                            if !sourceItems.isEmpty {
                                sourcePanel(source, items: sourceItems)
                            }
                        }
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
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Installers")
                    .font(.system(size: 20, weight: .bold))
                Text("Select redundant installer files to review before moving them to Trash.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(MoniPalette.foregroundTertiary)
            }

            Spacer(minLength: 12)

            Button {
                Task { await scan() }
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
            summaryCard("Found", installerBytes(totalSize), color: MoniPalette.green)
            summaryCard("Selected", installerBytes(selectedSize), color: MoniPalette.blue)
            summaryCard("Sources", activeSourceCount.formatted(), color: MoniPalette.orange)
            if unreadableItemCount > 0 {
                summaryCard("Unreadable", unreadableItemCount.formatted(), color: MoniPalette.red)
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

    private func sourcePanel(_ source: InstallerSource, items sourceItems: [InstallerCleanupItem]) -> some View {
        VStack(spacing: 0) {
            Button {
                toggle(sourceItems)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: selectionSymbol(sourceItems))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(MoniPalette.blue)
                        .frame(width: 20)
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
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Divider().padding(.horizontal, 12)

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
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(selectedPaths.contains(item.path) ? MoniPalette.selection.opacity(0.55) : Color.clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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

    private func scan() async {
        isScanning = true
        let snapshot = await InstallerCleanupService.scan()
        guard !Task.isCancelled else {
            isScanning = false
            return
        }
        items = snapshot.items
        unreadableItemCount = snapshot.unreadableItemCount
        selectedPaths = []
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
        monitor.refresh(forceSlowMetrics: true)

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
        let formatter = RelativeDateTimeFormatter()
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
