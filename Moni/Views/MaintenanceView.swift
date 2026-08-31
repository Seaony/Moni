import SwiftUI

private enum FinderMaintenanceAction: String, Identifiable {
    case finderCache
    case savedApplicationStates
    case brokenPreferences

    var id: String { rawValue }
}

private struct PendingMaintenanceAction: Identifiable {
    let action: FinderMaintenanceAction
    let plan: CleanupPlan

    var id: UUID { plan.id }
}

struct MaintenanceView: View {
    @EnvironmentObject private var monitor: SystemMonitor
    @State private var snapshot = FinderMaintenanceSnapshot(
        cachePaths: [],
        staleSavedStatePaths: [],
        unreadableItemCount: 0
    )
    @State private var isScanning = false
    @State private var isRunning = false
    @State private var brokenPreferencePaths: [String] = []
    @State private var preferenceUnreadableItemCount = 0
    @State private var pendingAction: PendingMaintenanceAction?
    @State private var resultMessage: String?

    var body: some View {
        VStack(spacing: 12) {
            header

            HStack(spacing: 12) {
                maintenanceCard(
                    title: "Finder Cache Refresh",
                    description: "Refresh Quick Look thumbnails and icon services caches.",
                    symbol: "photo.stack",
                    count: snapshot.cachePaths.count,
                    buttonTitle: "Review Refresh"
                ) {
                    Task { await prepare(.finderCache, paths: snapshot.cachePaths) }
                }

                maintenanceCard(
                    title: "App State Cleanup",
                    description: "Move saved application states older than 30 days to Trash.",
                    symbol: "clock.arrow.circlepath",
                    count: snapshot.staleSavedStatePaths.count,
                    buttonTitle: "Review Cleanup"
                ) {
                    Task { await prepare(.savedApplicationStates, paths: snapshot.staleSavedStatePaths) }
                }
            }

            maintenanceCard(
                title: "Broken Config Repair",
                description: "Find malformed third-party preference files and move them to Trash.",
                symbol: "wrench.and.screwdriver",
                count: brokenPreferencePaths.count,
                buttonTitle: "Review Repair"
            ) {
                Task { await prepare(.brokenPreferences, paths: brokenPreferencePaths) }
            }

            catalogSummary
        }
        .task { await scan() }
        .sheet(item: $pendingAction) { pending in
            MaintenanceConfirmationView(
                pending: pending,
                onCancel: { pendingAction = nil },
                onConfirm: {
                    pendingAction = nil
                    Task { await execute(pending) }
                }
            )
        }
        .alert("Maintenance result", isPresented: resultMessageBinding) {
            Button("OK") { resultMessage = nil }
        } message: {
            Text(resultMessage ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Maintenance")
                    .font(.system(size: 20, weight: .bold))
                Text("Review each action before Moni changes files or refreshes a system service.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(MoniPalette.foregroundTertiary)
            }

            Spacer(minLength: 12)

            if unreadableItemCount > 0 {
                Label(
                    MoniLocalization.format("%@ unreadable", unreadableItemCount.formatted()),
                    systemImage: "exclamationmark.triangle"
                )
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(MoniPalette.orange)
            }

            Button {
                Task { await scan() }
            } label: {
                Label(MoniLocalization.string("Rescan"), systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(isScanning || isRunning)
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

    private func maintenanceCard(
        title: String,
        description: String,
        symbol: String,
        count: Int,
        buttonTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(MoniPalette.blue)
                    .frame(width: 36, height: 36)
                    .background(MoniPalette.selection)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(MoniLocalization.string(title))
                        .font(.system(size: 14.5, weight: .bold))
                    Text(MoniLocalization.string(description))
                        .font(.system(size: 11.5))
                        .foregroundStyle(MoniPalette.foregroundTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 10) {
                Text(MoniLocalization.format("%@ files found", count.formatted()))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(count == 0 ? MoniPalette.foregroundTertiary : MoniPalette.orange)
                Spacer(minLength: 8)
                Button(MoniLocalization.string(buttonTitle), action: action)
                    .buttonStyle(.borderedProminent)
                    .disabled(isScanning || isRunning)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 164, alignment: .topLeading)
        .background(MoniPalette.card)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(MoniPalette.panelLine, lineWidth: 1)
        }
    }

    private var catalogSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Maintenance catalog")
                        .font(.system(size: 15, weight: .bold))
                    Text("The remaining tasks are being added in permission-aware batches.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(MoniPalette.foregroundTertiary)
                }
                Spacer()
                Text(MoniLocalization.format("%@ tasks", MaintenanceService.tasks.count.formatted()))
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(MoniPalette.foregroundSecondary)
            }

            Divider()

            HStack(spacing: 10) {
                catalogMetric("Available now", "3", MoniPalette.green)
                catalogMetric(
                    "Administrator access",
                    MaintenanceService.tasks.count { $0.authorization == .administrator }.formatted(),
                    MoniPalette.orange
                )
                catalogMetric(
                    "User-level tasks",
                    MaintenanceService.tasks.count { $0.authorization == .user }.formatted(),
                    MoniPalette.blue
                )
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(MoniPalette.card)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(MoniPalette.panelLine, lineWidth: 1)
        }
    }

    private func catalogMetric(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(MoniLocalization.string(title))
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(MoniPalette.foregroundTertiary)
            Text(value)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MoniPalette.insetSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private var resultMessageBinding: Binding<Bool> {
        Binding(
            get: { resultMessage != nil },
            set: { if !$0 { resultMessage = nil } }
        )
    }

    private var unreadableItemCount: Int {
        snapshot.unreadableItemCount + preferenceUnreadableItemCount
    }

    private func scan() async {
        isScanning = true
        async let finderResult = MaintenanceService.scanFinderMaintenance()
        async let preferenceResult = MaintenanceService.scanBrokenPreferences()
        let (finder, preferences) = await (finderResult, preferenceResult)
        guard !Task.isCancelled else { return }
        snapshot = finder
        brokenPreferencePaths = preferences.paths
        preferenceUnreadableItemCount = preferences.unreadableItemCount
        isScanning = false
    }

    private func prepare(_ action: FinderMaintenanceAction, paths: [String]) async {
        let plan = await CleanupService.shared.preview(paths: paths, scope: .maintenance)
        pendingAction = PendingMaintenanceAction(action: action, plan: plan)
    }

    private func execute(_ pending: PendingMaintenanceAction) async {
        isRunning = true
        let cleanupResult = await CleanupService.shared.execute(pending.plan)
        var parts: [String] = []

        if !cleanupResult.trashedPaths.isEmpty {
            parts.append(MoniLocalization.format(
                "Moved %@ items to Trash.",
                cleanupResult.trashedPaths.count.formatted()
            ))
        }
        if !cleanupResult.rejectedItems.isEmpty {
            parts.append(MoniLocalization.format(
                "%@ items were protected or changed.",
                cleanupResult.rejectedItems.count.formatted()
            ))
        }
        if !cleanupResult.failedPaths.isEmpty {
            parts.append(MoniLocalization.format(
                "%@ items could not be moved.",
                cleanupResult.failedPaths.count.formatted()
            ))
        }

        if pending.action == .finderCache {
            let refresh = await MaintenanceService.refreshFinderServices()
            if refresh.unavailable {
                parts.append(MoniLocalization.string("Finder refresh service is unavailable."))
            } else if refresh.quickLookCacheRefreshed && refresh.iconServicesRefreshed {
                parts.append(MoniLocalization.string("Quick Look and icon services were refreshed."))
            } else {
                parts.append(MoniLocalization.string("One or more Finder services could not be refreshed."))
            }
        } else if parts.isEmpty {
            let message = pending.action == .savedApplicationStates
                ? "No old application states needed cleanup."
                : "No damaged preference files needed repair."
            parts.append(MoniLocalization.string(message))
        }

        await scan()
        isRunning = false
        monitor.refresh(forceSlowMetrics: true)
        resultMessage = parts.joined(separator: " ")
    }
}

private struct MaintenanceConfirmationView: View {
    let pending: PendingMaintenanceAction
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(MoniLocalization.string(confirmationTitle))
                    .font(.system(size: 18, weight: .bold))
                Text(confirmationDescription)
                    .font(.system(size: 12))
                    .foregroundStyle(MoniPalette.foregroundTertiary)
            }

            if pending.plan.candidates.isEmpty {
                ContentUnavailableView(
                    "No files to move",
                    systemImage: "checkmark.circle",
                    description: Text(MoniLocalization.string(emptyDescription))
                )
                .frame(maxWidth: .infinity, minHeight: 170)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(pending.plan.candidates) { candidate in
                            Label {
                                Text(candidate.path)
                                    .font(.system(size: 11.5))
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                            } icon: {
                                Image(systemName: "trash")
                                    .foregroundStyle(MoniPalette.orange)
                            }
                        }
                    }
                    .padding(12)
                }
                .frame(maxHeight: 250)
                .background(MoniPalette.insetSecondary)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            if pending.action == .finderCache {
                Label("Quick Look and icon services will be rebuilt after cleanup.", systemImage: "arrow.clockwise")
                    .font(.system(size: 11.5))
                    .foregroundStyle(MoniPalette.foregroundSecondary)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Run Maintenance", role: .destructive, action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .disabled(pending.action != .finderCache && pending.plan.candidates.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 580)
    }

    private var confirmationDescription: String {
        switch pending.action {
        case .finderCache:
            MoniLocalization.string("Listed cache files will be moved to Trash before Finder services are refreshed.")
        case .savedApplicationStates:
            MoniLocalization.string("Listed saved states will be moved to Trash. Applications can recreate them when needed.")
        case .brokenPreferences:
            MoniLocalization.string("Listed malformed preference files will be moved to Trash. Applications can recreate them when needed.")
        }
    }

    private var confirmationTitle: String {
        switch pending.action {
        case .finderCache: "Refresh Finder caches?"
        case .savedApplicationStates: "Clean old application states?"
        case .brokenPreferences: "Repair broken preferences?"
        }
    }

    private var emptyDescription: String {
        switch pending.action {
        case .finderCache: "Finder services can still be refreshed."
        case .savedApplicationStates: "No saved application states older than 30 days were found."
        case .brokenPreferences: "No damaged third-party preference files were found."
        }
    }
}
