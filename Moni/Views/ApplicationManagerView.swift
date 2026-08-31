import AppKit
import SwiftUI

struct ApplicationManagerView: View {
    @EnvironmentObject private var monitor: SystemMonitor
    @State private var inventory = ApplicationInventorySnapshot(applications: [], unreadablePaths: [])
    @State private var selectedApplicationPath: String?
    @State private var removalPreview: ApplicationUninstallPreview?
    @State private var selectedRemovalPaths: Set<String> = []
    @State private var searchText = ""
    @State private var isScanning = false
    @State private var isPreparing = false
    @State private var pendingPlan: CleanupPlan?
    @State private var cleanupMessage: String?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            applicationList
                .frame(width: 330)
            removalDetails
        }
        .task {
            await scanApplications()
        }
        .sheet(item: $pendingPlan) { plan in
            CleanupConfirmationView(
                plan: plan,
                onCancel: { pendingPlan = nil },
                onConfirm: {
                    pendingPlan = nil
                    Task { await execute(plan) }
                }
            )
        }
        .alert("Uninstall result", isPresented: cleanupMessageBinding) {
            Button("OK") { cleanupMessage = nil }
        } message: {
            Text(cleanupMessage ?? "")
        }
    }

    private var applicationList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Applications")
                        .font(.system(size: 17, weight: .bold))
                    Text(MoniLocalization.format("%@ installed", inventory.applications.count.formatted()))
                        .font(.system(size: 10.5))
                        .foregroundStyle(MoniPalette.foregroundTertiary)
                }
                Spacer(minLength: 8)
                Button {
                    Task { await scanApplications() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(MoniPressButtonStyle())
                .disabled(isScanning || isPreparing)
                .help(MoniLocalization.string("Rescan"))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            TextField(MoniLocalization.string("Search applications"), text: $searchText)
                .textFieldStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(MoniPalette.control)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .padding(.horizontal, 12)
                .padding(.bottom, 10)

            Divider()

            if isScanning {
                VStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text("Scanning applications…")
                        .font(.system(size: 12))
                        .foregroundStyle(MoniPalette.foregroundTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 2) {
                        ForEach(filteredApplications) { application in
                            applicationRow(application)
                        }
                    }
                    .padding(6)
                }
            }
        }
        .background(MoniPalette.insetSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(MoniPalette.line, lineWidth: 1)
        }
    }

    private var removalDetails: some View {
        Group {
            if let application = selectedApplication {
                VStack(spacing: 0) {
                    applicationHeader(application)
                    Divider()

                    if isPreparing {
                        HStack(spacing: 9) {
                            ProgressView().controlSize(.small)
                            Text("Finding related files…")
                                .foregroundStyle(MoniPalette.foregroundTertiary)
                        }
                        .font(.system(size: 12.5))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let removalPreview {
                        removalList(removalPreview)
                    }
                }
            } else {
                ContentUnavailableView(
                    "Select an application",
                    systemImage: "app.badge",
                    description: Text("Review its application bundle and related user files before uninstalling.")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MoniPalette.insetSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(MoniPalette.line, lineWidth: 1)
        }
    }

    private func applicationRow(_ application: InstalledApplication) -> some View {
        Button {
            select(application)
        } label: {
            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: application.path))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(application.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Text(application.version ?? "—")
                        if let size = application.sizeBytes {
                            Text("·")
                            Text(appBytes(size))
                        }
                    }
                    .font(.system(size: 10.5))
                    .foregroundStyle(MoniPalette.foregroundTertiary)
                }
                Spacer(minLength: 6)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(selectedApplicationPath == application.path ? MoniPalette.selection : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(MoniPressButtonStyle(scale: 0.99))
    }

    private func applicationHeader(_ application: InstalledApplication) -> some View {
        HStack(spacing: 14) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: application.path))
                .resizable()
                .interpolation(.high)
                .frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text(application.name)
                    .font(.system(size: 17, weight: .bold))
                Text(application.bundleIdentifier ?? application.path)
                    .font(.system(size: 11.5))
                    .foregroundStyle(MoniPalette.foregroundTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 10)
            Button {
                Task { await prepareRemoval(application) }
            } label: {
                Label(MoniLocalization.string("Review Removal"), systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .tint(MoniPalette.red)
            .disabled(selectedRemovalPaths.isEmpty || isPreparing || officialVendor != nil)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func removalList(_ preview: ApplicationUninstallPreview) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                if let officialVendor {
                    warningBanner(
                        MoniLocalization.format("Use the official %@ uninstaller for this application.", officialVendor),
                        color: MoniPalette.red,
                        symbol: "exclamationmark.shield.fill"
                    )
                }
                ForEach(preview.warnings, id: \.self) { warning in
                    warningBanner(uninstallWarning(warning), color: MoniPalette.orange, symbol: "shield.fill")
                }

                HStack {
                    Text(MoniLocalization.format("%@ files selected", selectedRemovalPaths.count.formatted()))
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text(appBytes(selectedSize(in: preview)))
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(MoniPalette.foregroundSecondary)
                }

                VStack(spacing: 2) {
                    ForEach(preview.items) { item in
                        let required = item.kind == .applicationBundle
                        Button {
                            if !required { toggleRemoval(item.path) }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: selectedRemovalPaths.contains(item.path) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(required ? MoniPalette.purple : MoniPalette.blue)
                                    .frame(width: 18)
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
                                Spacer(minLength: 8)
                                Text(item.sizeBytes.map(appBytes) ?? "—")
                                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                                    .foregroundStyle(MoniPalette.foregroundSecondary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(selectedRemovalPaths.contains(item.path) ? MoniPalette.selection.opacity(0.55) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(14)
        }
    }

    private func warningBanner(_ text: String, color: Color, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var filteredApplications: [InstalledApplication] {
        guard !searchText.isEmpty else { return inventory.applications }
        return inventory.applications.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
                || $0.bundleIdentifier?.localizedCaseInsensitiveContains(searchText) == true
        }
    }

    private var selectedApplication: InstalledApplication? {
        inventory.applications.first { $0.path == selectedApplicationPath }
    }

    private var officialVendor: String? {
        selectedApplication.flatMap(ApplicationUninstallService.officialUninstallerVendor)
    }

    private var cleanupMessageBinding: Binding<Bool> {
        Binding(
            get: { cleanupMessage != nil },
            set: { if !$0 { cleanupMessage = nil } }
        )
    }

    private func select(_ application: InstalledApplication) {
        selectedApplicationPath = application.path
        removalPreview = nil
        selectedRemovalPaths = []
        Task { await loadPreview(for: application) }
    }

    private func scanApplications() async {
        isScanning = true
        let snapshot = await ApplicationInventoryService.scan()
        guard !Task.isCancelled else { return }
        inventory = snapshot
        isScanning = false

        if let selectedApplicationPath,
           let application = snapshot.applications.first(where: { $0.path == selectedApplicationPath }) {
            await loadPreview(for: application)
        } else {
            self.selectedApplicationPath = snapshot.applications.first?.path
            if let application = snapshot.applications.first {
                await loadPreview(for: application)
            }
        }
    }

    private func loadPreview(for application: InstalledApplication) async {
        isPreparing = true
        let preview = await ApplicationUninstallService.preview(application: application, inventory: inventory)
        guard !Task.isCancelled, selectedApplicationPath == application.path else { return }
        removalPreview = preview
        selectedRemovalPaths = Set(preview.items.map(\.path))
        isPreparing = false
    }

    private func toggleRemoval(_ path: String) {
        if selectedRemovalPaths.contains(path) {
            selectedRemovalPaths.remove(path)
        } else {
            selectedRemovalPaths.insert(path)
        }
    }

    private func prepareRemoval(_ application: InstalledApplication) async {
        guard ApplicationUninstallService.officialUninstallerVendor(for: application) == nil else {
            cleanupMessage = MoniLocalization.string("This application requires its official uninstaller.")
            return
        }
        guard !isRunning(application) else {
            cleanupMessage = MoniLocalization.format("Quit %@ before uninstalling it.", application.name)
            return
        }
        let plan = await CleanupService.shared.preview(
            paths: Array(selectedRemovalPaths),
            scope: .applications
        )
        if plan.candidates.isEmpty {
            cleanupMessage = MoniLocalization.string("No selected items can be cleaned.")
        } else {
            pendingPlan = plan
        }
    }

    private func execute(_ confirmedPlan: CleanupPlan) async {
        guard let application = selectedApplication else { return }
        guard ApplicationUninstallService.officialUninstallerVendor(for: application) == nil else {
            cleanupMessage = MoniLocalization.string("This application requires its official uninstaller.")
            return
        }
        guard !isRunning(application) else {
            cleanupMessage = MoniLocalization.format("Quit %@ before uninstalling it.", application.name)
            return
        }

        isPreparing = true
        let currentInventory = await ApplicationInventoryService.scan()
        let currentApplication = currentInventory.applications.first {
            $0.path == application.path && $0.device == application.device && $0.inode == application.inode
        }
        let allowedPaths: Set<String>
        if let currentApplication {
            let currentPreview = await ApplicationUninstallService.preview(
                application: currentApplication,
                inventory: currentInventory
            )
            allowedPaths = Set(currentPreview.items.map(\.path))
        } else {
            allowedPaths = [application.path]
        }
        let finalPlan = CleanupPlan(
            id: confirmedPlan.id,
            createdAt: confirmedPlan.createdAt,
            scope: confirmedPlan.scope,
            candidates: confirmedPlan.candidates.filter { allowedPaths.contains($0.path) },
            rejectedItems: confirmedPlan.rejectedItems
        )
        let result = await CleanupService.shared.execute(finalPlan)
        isPreparing = false
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
        cleanupMessage = parts.isEmpty ? MoniLocalization.string("Nothing was moved.") : parts.joined(separator: " ")
        await scanApplications()
    }

    private func isRunning(_ application: InstalledApplication) -> Bool {
        NSWorkspace.shared.runningApplications.contains { running in
            if let bundleIdentifier = application.bundleIdentifier,
               running.bundleIdentifier?.caseInsensitiveCompare(bundleIdentifier) == .orderedSame {
                return true
            }
            return running.bundleURL?.resolvingSymlinksInPath().standardizedFileURL.path == application.canonicalPath
        }
    }

    private func selectedSize(in preview: ApplicationUninstallPreview) -> UInt64 {
        preview.items.reduce(into: 0) { total, item in
            if selectedRemovalPaths.contains(item.path) {
                total += item.sizeBytes ?? 0
            }
        }
    }

    private func uninstallWarning(_ warning: ApplicationUninstallWarning) -> String {
        let key = switch warning {
        case .incompleteApplicationInventory:
            "Some applications could not be read. Shared related files are excluded."
        case .sharedBundleIdentifier:
            "Another installation uses the same bundle identifier. Only this application bundle is included."
        case .incompleteResidualScan:
            "Some related-file locations could not be read and were left untouched."
        }
        return MoniLocalization.string(key)
    }
}

private func appBytes(_ value: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
}
