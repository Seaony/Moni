import SwiftUI

struct TrashCleanerView: View {
    @EnvironmentObject private var monitor: SystemMonitor
    @State private var items: [TrashCleanupItem] = []
    @State private var selectedPaths: Set<String> = []
    @State private var unreadableItemCount = 0
    @State private var rootDevice: UInt64?
    @State private var rootInode: UInt64?
    @State private var isScanning = false
    @State private var isCleaning = false
    @State private var pendingPlan: TrashCleanupPlan?
    @State private var cleanupMessage: String?

    var body: some View {
        VStack(spacing: 12) {
            header
            summary

            if isScanning {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Scanning Trash…")
                        .font(.system(size: 12.5))
                        .foregroundStyle(MoniPalette.foregroundTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                ContentUnavailableView(
                    "Trash is empty",
                    systemImage: "trash",
                    description: Text("No removable items were found in the current user's Trash.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    itemPanel
                }
            }
        }
        .task { await scan() }
        .sheet(item: $pendingPlan) { plan in
            TrashCleanupConfirmationView(
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
                Text("Trash")
                    .font(.system(size: 20, weight: .bold))
                Text("Review Trash items before deleting them permanently. This action cannot be undone.")
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
                    systemImage: "trash.slash"
                )
            }
            .buttonStyle(.borderedProminent)
            .tint(MoniPalette.red)
            .disabled(selectedPaths.isEmpty || rootDevice == nil || rootInode == nil || isScanning || isCleaning)
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
            summaryCard("Reclaimable", trashBytes(totalSize), color: MoniPalette.green)
            summaryCard("Selected", trashBytes(selectedSize), color: MoniPalette.blue)
            summaryCard("Items", items.count.formatted(), color: MoniPalette.orange)
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

    private var itemPanel: some View {
        VStack(spacing: 0) {
            Button {
                toggleAll()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: selectionSymbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(MoniPalette.blue)
                        .frame(width: 20)
                    Text("Current user Trash")
                        .font(.system(size: 13.5, weight: .bold))
                    Spacer(minLength: 10)
                    Text(trashBytes(totalSize))
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(MoniPalette.foregroundSecondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Divider().padding(.horizontal, 12)

            ForEach(items) { item in
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
                            Text(item.path)
                                .font(.system(size: 10.5))
                                .foregroundStyle(MoniPalette.foregroundTertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 10)
                        Text(trashBytes(item.sizeBytes))
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

    private var selectionSymbol: String {
        if selectedPaths.count == items.count { return "checkmark.square.fill" }
        if !selectedPaths.isEmpty { return "minus.square.fill" }
        return "square"
    }

    private var cleanupMessageBinding: Binding<Bool> {
        Binding(
            get: { cleanupMessage != nil },
            set: { if !$0 { cleanupMessage = nil } }
        )
    }

    private func toggle(_ path: String) {
        if selectedPaths.contains(path) {
            selectedPaths.remove(path)
        } else {
            selectedPaths.insert(path)
        }
    }

    private func toggleAll() {
        let paths = Set(items.map(\.path))
        if paths.isSubset(of: selectedPaths) {
            selectedPaths.removeAll()
        } else {
            selectedPaths = paths
        }
    }

    private func scan() async {
        isScanning = true
        let snapshot = await TrashCleanupService.scan()
        guard !Task.isCancelled else {
            isScanning = false
            return
        }
        items = snapshot.items
        selectedPaths = []
        unreadableItemCount = snapshot.unreadableItemCount
        rootDevice = snapshot.rootDevice
        rootInode = snapshot.rootInode
        isScanning = false
    }

    private func prepareCleanup() async {
        guard let rootDevice, let rootInode else {
            cleanupMessage = MoniLocalization.string("Trash could not be verified.")
            return
        }
        let selectedItems = items.filter { selectedPaths.contains($0.path) }
        let plan = await TrashCleanupService.previewCleanup(
            items: selectedItems,
            rootDevice: rootDevice,
            rootInode: rootInode
        )
        if plan.cleanupPlan.candidates.isEmpty {
            cleanupMessage = MoniLocalization.string("No selected items can be cleaned.")
        } else {
            pendingPlan = plan
        }
    }

    private func execute(_ plan: TrashCleanupPlan) async {
        isCleaning = true
        let result = await TrashCleanupService.executeCleanup(plan)
        await scan()
        isCleaning = false
        monitor.refresh(forceSlowMetrics: true)

        var parts: [String] = []
        if !result.trashedPaths.isEmpty {
            parts.append(MoniLocalization.format("Permanently deleted %@ items.", result.trashedPaths.count.formatted()))
        }
        if !result.rejectedItems.isEmpty {
            parts.append(MoniLocalization.format("%@ items were protected or changed.", result.rejectedItems.count.formatted()))
        }
        if !result.failedPaths.isEmpty {
            parts.append(MoniLocalization.format("%@ items could not be deleted.", result.failedPaths.count.formatted()))
        }
        cleanupMessage = parts.joined(separator: " ")
    }

    private func addingWithoutOverflow(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : sum
    }
}

private struct TrashCleanupConfirmationView: View {
    let plan: CleanupPlan
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(MoniPalette.red)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Delete Trash items permanently?")
                        .font(.system(size: 20, weight: .bold))
                    Text("The approved items below will be deleted immediately and cannot be recovered from Trash.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(MoniPalette.foregroundSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 7) {
                    ForEach(plan.candidates) { candidate in
                        Text(candidate.path)
                            .font(.system(size: 12.5, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(MoniPalette.inset)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
            }
            .frame(minHeight: 190, maxHeight: 310)

            HStack(spacing: 10) {
                Spacer()
                Button(MoniLocalization.string("Cancel"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(MoniLocalization.string("Delete Permanently"), role: .destructive, action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .tint(MoniPalette.red)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 620)
        .background(MoniPalette.card)
    }
}

private func trashBytes(_ value: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
}
