import SwiftUI

private enum FinderMaintenanceAction: String, Identifiable {
    case finderCache
    case savedApplicationStates
    case brokenPreferences
    case sharedFileLists
    case launchAgents

    var id: String { rawValue }
}

private struct PendingMaintenanceAction: Identifiable {
    let action: FinderMaintenanceAction
    let plan: CleanupPlan

    var id: UUID { plan.id }
}

private struct LegacyOverrideReview: Identifiable {
    let id = UUID()
    let overrides: [LegacySystemOverride]
}

private struct DiskVerificationReport: Identifiable {
    let id = UUID()
    let result: DiskVerificationResult
}

private struct DatabaseMaintenanceReview: Identifiable {
    let id = UUID()
    let items: [DatabaseMaintenanceItem]
}

private struct SpotlightRulesReview: Identifiable {
    let id = UUID()
    let rules: [String]
}

private struct LoginItemsReview: Identifiable {
    let id = UUID()
    let items: [BrokenLoginItem]
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
    @State private var fileRepairSnapshot = MaintenanceFileRepairSnapshot(
        brokenSharedFileListPaths: [],
        brokenLaunchAgentPaths: [],
        unreadableItemCount: 0
    )
    @State private var settingsSnapshot = MaintenanceSettingsSnapshot(
        dsStoreKeysToEnable: [],
        legacyOverrides: [],
        launchServicesAvailable: false
    )
    @State private var quarantineSnapshot = QuarantineMaintenanceSnapshot(
        databasePath: "",
        entryCount: 0,
        state: .unavailable
    )
    @State private var databaseSnapshot = DatabaseMaintenanceSnapshot(
        availability: .unavailable,
        busyApplications: [],
        items: []
    )
    @State private var spotlightRulesSnapshot = SpotlightRulesMaintenanceSnapshot(
        state: .unavailable,
        orphanedRules: []
    )
    @State private var loginItemsSnapshot = LoginItemsAuditSnapshot(
        state: .unavailable,
        checkedCount: 0,
        brokenItems: []
    )
    @State private var notificationSnapshot = NotificationMaintenanceSnapshot(
        path: "",
        sizeBytes: 0,
        state: .unavailable,
        device: 0,
        inode: 0
    )
    @State private var coreDuetSnapshot = CoreDuetMaintenanceSnapshot(
        databasePath: "",
        totalSizeBytes: 0,
        state: .unavailable,
        files: []
    )
    @State private var systemMaintenanceSnapshot = SystemMaintenanceSnapshot(
        spotlightStatus: .unavailable
    )
    @State private var networkStackState: NetworkStackState = .unavailable
    @State private var permissionRepairState: PermissionRepairState = .unavailable
    @State private var spotlightOptimizationState: SpotlightOptimizationState = .unavailable
    @State private var periodicMaintenanceSnapshot = PeriodicMaintenanceSnapshot(
        state: .unavailable,
        ageDays: nil
    )
    @State private var tartCacheSnapshot = TartCacheMaintenanceSnapshot(
        path: "",
        sizeBytes: 0,
        state: .unavailable
    )
    @State private var timeMachineSnapshotReport = TimeMachineSnapshotReport(
        state: .unavailable,
        snapshotCount: 0,
        incompleteBackups: [],
        unreadableItemCount: 0
    )
    @State private var pendingTimeMachineCleanup: TimeMachineBackupCleanupPlan?
    @State private var systemCleanupSnapshot = SystemCleanupSnapshot(
        state: .notScanned,
        items: [],
        unreadableItemCount: 0,
        activePowerLogNotice: nil
    )
    @State private var pendingSystemCleanup: SystemCleanupPlan?
    @State private var pendingAction: PendingMaintenanceAction?
    @State private var confirmsLaunchServicesRepair = false
    @State private var confirmsDSStorePrevention = false
    @State private var confirmsQuarantineCleanup = false
    @State private var legacyOverrideReview: LegacyOverrideReview?
    @State private var confirmsDiskVerification = false
    @State private var diskVerificationReport: DiskVerificationReport?
    @State private var databaseReview: DatabaseMaintenanceReview?
    @State private var spotlightRulesReview: SpotlightRulesReview?
    @State private var loginItemsReview: LoginItemsReview?
    @State private var confirmsNotificationCleanup = false
    @State private var confirmsCoreDuetCleanup = false
    @State private var confirmsSystemMaintenance = false
    @State private var confirmsNetworkCacheRefresh = false
    @State private var confirmsNetworkStackRefresh = false
    @State private var confirmsPermissionRepair = false
    @State private var confirmsSpotlightOptimization = false
    @State private var confirmsPeriodicMaintenance = false
    @State private var confirmsTartCachePrune = false
    @State private var resultMessage: String?

    var body: some View {
        VStack(spacing: 12) {
            header

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 12) {
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

                    HStack(spacing: 12) {
                        maintenanceCard(
                            title: "Shared File Lists",
                            description: "Find malformed Finder favorites and shared file lists.",
                            symbol: "list.bullet.rectangle",
                            count: fileRepairSnapshot.brokenSharedFileListPaths.count,
                            buttonTitle: "Review Repair"
                        ) {
                            Task {
                                await prepare(
                                    .sharedFileLists,
                                    paths: fileRepairSnapshot.brokenSharedFileListPaths
                                )
                            }
                        }

                        maintenanceCard(
                            title: "Launch Agents Cleanup",
                            description: "Unload user LaunchAgents whose executable no longer exists.",
                            symbol: "bolt.badge.xmark",
                            count: fileRepairSnapshot.brokenLaunchAgentPaths.count,
                            buttonTitle: "Review Cleanup"
                        ) {
                            Task {
                                await prepare(
                                    .launchAgents,
                                    paths: fileRepairSnapshot.brokenLaunchAgentPaths
                                )
                            }
                        }
                    }

                    commandCard(
                        title: "DNS & Spotlight Check",
                        description: "Refresh DNS cache and verify Spotlight status.",
                        symbol: "checkmark.shield",
                        status: systemMaintenanceStatus,
                        buttonTitle: "Review Check",
                        isAvailable: systemMaintenanceSnapshot.spotlightStatus != .unavailable
                    ) {
                        confirmsSystemMaintenance = true
                    }

                    commandCard(
                        title: "Network Cache Refresh",
                        description: "Flush the DNS cache and restart mDNSResponder.",
                        symbol: "network",
                        status: "Administrator access",
                        buttonTitle: "Review Refresh",
                        isAvailable: true
                    ) {
                        confirmsNetworkCacheRefresh = true
                    }

                    commandCard(
                        title: "Network Stack Refresh",
                        description: "Flush routing and ARP caches to resolve network issues.",
                        symbol: "point.3.connected.trianglepath.dotted",
                        status: networkStackStatus,
                        buttonTitle: networkStackButtonTitle,
                        isAvailable: networkStackIsAvailable,
                        isActionEnabled: networkStackState == .needsRefresh
                    ) {
                        confirmsNetworkStackRefresh = true
                    }

                    commandCard(
                        title: "Permission Repair",
                        description: "Reset permissions for the current user home directory.",
                        symbol: "person.badge.key",
                        status: permissionRepairStatus,
                        buttonTitle: permissionRepairButtonTitle,
                        isAvailable: permissionRepairState != .unavailable,
                        isActionEnabled: permissionRepairState == .needsRepair
                    ) {
                        confirmsPermissionRepair = true
                    }

                    commandCard(
                        title: "Spotlight Optimization",
                        description: "Inspect Spotlight and rebuild the startup volume index only when needed.",
                        symbol: "magnifyingglass.circle",
                        status: spotlightOptimizationStatus,
                        buttonTitle: spotlightOptimizationButtonTitle,
                        isAvailable: spotlightOptimizationIsAvailable,
                        isActionEnabled: spotlightOptimizationState == .slow
                    ) {
                        confirmsSpotlightOptimization = true
                    }

                    commandCard(
                        title: "Periodic Maintenance",
                        description: "Run macOS daily, weekly, and monthly maintenance scripts when stale.",
                        symbol: "calendar.badge.clock",
                        status: periodicMaintenanceStatus,
                        buttonTitle: periodicMaintenanceButtonTitle,
                        isAvailable: periodicMaintenanceSnapshot.state != .unavailable
                            && periodicMaintenanceSnapshot.state != .failed,
                        isActionEnabled: periodicMaintenanceSnapshot.state == .stale
                            || periodicMaintenanceSnapshot.state == .missingLog
                    ) {
                        confirmsPeriodicMaintenance = true
                    }

                    commandCard(
                        title: "Tart Cache Pruning",
                        description: "Prune Tart cache entries older than 30 days using Tart's own maintenance command.",
                        symbol: "shippingbox",
                        status: tartCacheStatus,
                        buttonTitle: tartCacheButtonTitle,
                        isAvailable: tartCacheSnapshot.state != .unavailable
                            && tartCacheSnapshot.state != .failed,
                        isActionEnabled: tartCacheSnapshot.state == .ready
                    ) {
                        confirmsTartCachePrune = true
                    }

                    commandCard(
                        title: "Time Machine",
                        description: "Report local snapshots and review incomplete backups for removal with tmutil.",
                        symbol: "clock.arrow.trianglehead.counterclockwise.rotate.90",
                        status: timeMachineSnapshotStatus,
                        buttonTitle: timeMachineCleanupButtonTitle,
                        isAvailable: timeMachineSnapshotReport.state != .unavailable
                            && timeMachineSnapshotReport.state != .failed,
                        isActionEnabled: !timeMachineSnapshotReport.incompleteBackups.isEmpty
                    ) {
                        Task { await prepareTimeMachineCleanup() }
                    }

                    commandCard(
                        title: "System Cleanup",
                        description: "Scan old system caches and logs before approving cleanup.",
                        symbol: "externaldrive.badge.minus",
                        status: systemCleanupStatus,
                        buttonTitle: systemCleanupButtonTitle,
                        isAvailable: systemCleanupSnapshot.state != .unavailable,
                        isActionEnabled: systemCleanupSnapshot.state != .unavailable
                    ) {
                        Task {
                            if systemCleanupSnapshot.state == .ready {
                                await prepareSystemCleanup()
                            } else {
                                await scanSystemCleanup()
                            }
                        }
                    }

                    commandCard(
                        title: "LaunchServices Repair",
                        description: "Rebuild file associations and the Open With menu.",
                        symbol: "doc.badge.gearshape",
                        status: settingsSnapshot.launchServicesAvailable ? "Available" : "Unavailable",
                        buttonTitle: "Review Repair",
                        isAvailable: settingsSnapshot.launchServicesAvailable
                    ) {
                        confirmsLaunchServicesRepair = true
                    }

                    commandCard(
                        title: "Prevent Finder .DS_Store",
                        description: "Stop Finder from writing .DS_Store files on network and USB volumes.",
                        symbol: "externaldrive.badge.xmark",
                        status: dsStoreStatus,
                        buttonTitle: settingsSnapshot.dsStoreKeysToEnable.isEmpty ? "Enabled" : "Review Enable",
                        isAvailable: true,
                        isActionEnabled: !settingsSnapshot.dsStoreKeysToEnable.isEmpty
                    ) {
                        confirmsDSStorePrevention = true
                    }

                    commandCard(
                        title: "Legacy Overrides",
                        description: "Restore macOS defaults for hidden App Nap and disk image verification settings.",
                        symbol: "slider.horizontal.3",
                        status: legacyOverrideStatus,
                        buttonTitle: settingsSnapshot.legacyOverrides.isEmpty ? "No overrides" : "Review Repair",
                        isAvailable: true,
                        isActionEnabled: !settingsSnapshot.legacyOverrides.isEmpty
                    ) {
                        legacyOverrideReview = LegacyOverrideReview(
                            overrides: settingsSnapshot.legacyOverrides
                        )
                    }

                    commandCard(
                        title: "Quarantine Database Cleanup",
                        description: "Clear Gatekeeper download history without changing file quarantine flags.",
                        symbol: "lock.doc",
                        status: quarantineStatus,
                        buttonTitle: quarantineSnapshot.entryCount > 0 ? "Review Cleanup" : "No history",
                        isAvailable: quarantineSnapshot.state == .ready,
                        isActionEnabled: quarantineSnapshot.entryCount > 0
                    ) {
                        confirmsQuarantineCleanup = true
                    }

                    commandCard(
                        title: "Disk Health",
                        description: "Verify the startup filesystem without modifying or repairing it.",
                        symbol: "internaldrive",
                        status: diskVerificationStatus,
                        buttonTitle: "Review Verify",
                        isAvailable: MaintenanceDiagnosticsService.diskVerificationIsAvailable
                    ) {
                        confirmsDiskVerification = true
                    }

                    commandCard(
                        title: "Database Optimization",
                        description: "Compact supported Mail, Safari, and Messages databases while their apps are closed.",
                        symbol: "cylinder.split.1x2",
                        status: databaseMaintenanceStatus,
                        buttonTitle: "Review Optimization",
                        isAvailable: databaseMaintenanceIsAvailable,
                        isActionEnabled: !databaseSnapshot.items.isEmpty
                    ) {
                        databaseReview = DatabaseMaintenanceReview(items: databaseSnapshot.items)
                    }

                    commandCard(
                        title: "Spotlight Orphan Rules",
                        description: "Remove Spotlight search rules that reference applications no longer installed.",
                        symbol: "magnifyingglass",
                        status: spotlightRulesStatus,
                        buttonTitle: spotlightRulesSnapshot.orphanedRules.isEmpty
                            ? "No orphan rules"
                            : "Review Repair",
                        isAvailable: spotlightRulesSnapshot.state == .ready,
                        isActionEnabled: !spotlightRulesSnapshot.orphanedRules.isEmpty
                    ) {
                        spotlightRulesReview = SpotlightRulesReview(
                            rules: spotlightRulesSnapshot.orphanedRules
                        )
                    }

                    commandCard(
                        title: "Login Items",
                        description: "Find login items whose referenced application or executable no longer exists.",
                        symbol: "rectangle.stack.badge.person.crop",
                        status: loginItemsStatus,
                        buttonTitle: loginItemsSnapshot.brokenItems.isEmpty ? "Healthy" : "Review Audit",
                        isAvailable: loginItemsSnapshot.state == .ready,
                        isActionEnabled: !loginItemsSnapshot.brokenItems.isEmpty
                    ) {
                        loginItemsReview = LoginItemsReview(items: loginItemsSnapshot.brokenItems)
                    }

                    commandCard(
                        title: "Notifications",
                        description: "Remove old delivered notifications to reduce notification database size.",
                        symbol: "bell.badge",
                        status: notificationStatus,
                        buttonTitle: notificationSnapshot.state == .ready ? "Review Cleanup" : "Healthy",
                        isAvailable: notificationSnapshot.state == .ready
                            || notificationSnapshot.state == .healthy,
                        isActionEnabled: notificationSnapshot.state == .ready
                    ) {
                        confirmsNotificationCleanup = true
                    }

                    commandCard(
                        title: "Usage Data",
                        description: "Remove old local usage-tracking records from supported system databases.",
                        symbol: "chart.bar.xaxis",
                        status: coreDuetStatus,
                        buttonTitle: coreDuetSnapshot.state == .ready ? "Review Cleanup" : "Healthy",
                        isAvailable: coreDuetSnapshot.state == .ready
                            || coreDuetSnapshot.state == .healthy,
                        isActionEnabled: coreDuetSnapshot.state == .ready
                    ) {
                        confirmsCoreDuetCleanup = true
                    }

                    catalogSummary
                }
            }
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
        .sheet(item: $legacyOverrideReview) { review in
            LegacyOverrideConfirmationView(
                overrides: review.overrides,
                onCancel: { legacyOverrideReview = nil },
                onConfirm: {
                    legacyOverrideReview = nil
                    Task { await removeLegacyOverrides(review.overrides) }
                }
            )
        }
        .sheet(item: $diskVerificationReport) { report in
            DiskVerificationReportView(
                report: report,
                onClose: { diskVerificationReport = nil }
            )
        }
        .sheet(item: $databaseReview) { review in
            DatabaseMaintenanceConfirmationView(
                items: review.items,
                onCancel: { databaseReview = nil },
                onConfirm: {
                    databaseReview = nil
                    Task { await optimizeDatabases(review.items) }
                }
            )
        }
        .sheet(item: $spotlightRulesReview) { review in
            SpotlightRulesConfirmationView(
                rules: review.rules,
                onCancel: { spotlightRulesReview = nil },
                onConfirm: {
                    spotlightRulesReview = nil
                    Task { await removeSpotlightRules(review.rules) }
                }
            )
        }
        .sheet(item: $loginItemsReview) { review in
            LoginItemsAuditView(
                items: review.items,
                onClose: { loginItemsReview = nil }
            )
        }
        .sheet(item: $pendingTimeMachineCleanup) { plan in
            TimeMachineBackupCleanupConfirmationView(
                plan: plan,
                onCancel: { pendingTimeMachineCleanup = nil },
                onConfirm: {
                    pendingTimeMachineCleanup = nil
                    Task { await executeTimeMachineCleanup(plan) }
                }
            )
        }
        .sheet(item: $pendingSystemCleanup) { plan in
            SystemCleanupConfirmationView(
                plan: plan,
                onCancel: { pendingSystemCleanup = nil },
                onConfirm: {
                    pendingSystemCleanup = nil
                    Task { await executeSystemCleanup(plan) }
                }
            )
        }
        .alert("Maintenance result", isPresented: resultMessageBinding) {
            Button("OK") { resultMessage = nil }
        } message: {
            Text(resultMessage ?? "")
        }
        .confirmationDialog(
            "Rebuild LaunchServices?",
            isPresented: $confirmsLaunchServicesRepair,
            titleVisibility: .visible
        ) {
            Button("Run Maintenance") {
                Task { await rebuildLaunchServices() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("macOS will rebuild file associations and the Open With menu. No documents or applications will be removed.")
        }
        .confirmationDialog(
            "Prevent Finder .DS_Store files?",
            isPresented: $confirmsDSStorePrevention,
            titleVisibility: .visible
        ) {
            Button("Enable Prevention") {
                Task { await enableDSStorePrevention() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Finder will stop creating .DS_Store metadata files on network shares and removable USB volumes. Local folders are unchanged.")
        }
        .confirmationDialog(
            "Clear Gatekeeper download history?",
            isPresented: $confirmsQuarantineCleanup,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) {
                Task { await clearQuarantineHistory() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(MoniLocalization.format(
                "%@ download records will be deleted from %@. Existing file quarantine flags are unchanged.",
                quarantineSnapshot.entryCount.formatted(),
                quarantineSnapshot.databasePath
            ))
        }
        .confirmationDialog(
            "Verify the startup volume?",
            isPresented: $confirmsDiskVerification,
            titleVisibility: .visible
        ) {
            Button("Start Verification") {
                Task { await verifyStartupVolume() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This read-only APFS check can create sustained disk activity and may take several minutes. It will not repair the volume.")
        }
        .confirmationDialog(
            "Clean old notifications?",
            isPresented: $confirmsNotificationCleanup,
            titleVisibility: .visible
        ) {
            Button("Clean Notifications", role: .destructive) {
                Task { await cleanNotifications() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(MoniLocalization.format(
                "Delivered notifications older than 30 days will be deleted and the %@ database at %@ will be compacted.",
                maintenanceBytes(notificationSnapshot.sizeBytes),
                notificationSnapshot.path
            ))
        }
        .confirmationDialog(
            "Clean old usage data?",
            isPresented: $confirmsCoreDuetCleanup,
            titleVisibility: .visible
        ) {
            Button("Clean Usage Data", role: .destructive) {
                Task { await cleanCoreDuetData() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(MoniLocalization.format(
                "Usage records older than 90 days will be deleted from %@. WAL and SHM sidecar files are moved to Trash first. Current combined size: %@.",
                coreDuetSnapshot.databasePath,
                maintenanceBytes(coreDuetSnapshot.totalSizeBytes)
            ))
        }
        .confirmationDialog(
            "Refresh DNS and check Spotlight?",
            isPresented: $confirmsSystemMaintenance,
            titleVisibility: .visible
        ) {
            Button("Run Administrator Check") {
                Task { await runSystemMaintenance() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("macOS will request administrator approval to flush the DNS cache and restart mDNSResponder. Spotlight status is checked without changing the index.")
        }
        .confirmationDialog(
            "Refresh the network cache?",
            isPresented: $confirmsNetworkCacheRefresh,
            titleVisibility: .visible
        ) {
            Button("Refresh Network Cache") {
                Task { await refreshNetworkCache() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("macOS will request administrator approval to flush the DNS cache and restart mDNSResponder. The cache is rebuilt automatically as names are resolved again.")
        }
        .confirmationDialog(
            "Refresh the network stack?",
            isPresented: $confirmsNetworkStackRefresh,
            titleVisibility: .visible
        ) {
            Button("Refresh Network Stack") {
                Task { await refreshNetworkStack() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("macOS will request administrator approval to flush the routing table and ARP cache. Network connections may be interrupted briefly while routes are rebuilt.")
        }
        .confirmationDialog(
            "Repair user permissions?",
            isPresented: $confirmsPermissionRepair,
            titleVisibility: .visible
        ) {
            Button("Repair Permissions") {
                Task { await repairUserPermissions() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("macOS will request administrator approval to reset permissions for the current user on the startup volume. The operation may take several minutes.")
        }
        .confirmationDialog(
            "Rebuild the Spotlight index?",
            isPresented: $confirmsSpotlightOptimization,
            titleVisibility: .visible
        ) {
            Button("Start Index Rebuild") {
                Task { await optimizeSpotlight() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Two consecutive searches exceeded the speed threshold. macOS will request administrator approval to rebuild the startup volume index; indexing continues in the background and may take 1–2 hours.")
        }
        .confirmationDialog(
            "Run periodic maintenance?",
            isPresented: $confirmsPeriodicMaintenance,
            titleVisibility: .visible
        ) {
            Button("Run Periodic Maintenance") {
                Task { await runPeriodicMaintenance() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("macOS will request administrator approval to run the daily, weekly, and monthly maintenance scripts. Existing maintenance logs are retained.")
        }
        .confirmationDialog(
            "Prune old Tart caches?",
            isPresented: $confirmsTartCachePrune,
            titleVisibility: .visible
        ) {
            Button("Prune Tart Caches", role: .destructive) {
                Task { await pruneTartCaches() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(MoniLocalization.format(
                "Tart will remove cache entries older than 30 days from %@. The cache currently uses %@.",
                tartCacheSnapshot.path,
                maintenanceBytes(tartCacheSnapshot.sizeBytes)
            ))
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

    private func commandCard(
        title: String,
        description: String,
        symbol: String,
        status: String,
        buttonTitle: String,
        isAvailable: Bool,
        isActionEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(MoniPalette.purple)
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
                Text(MoniLocalization.string(status))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(isAvailable ? MoniPalette.green : MoniPalette.foregroundTertiary)
                Spacer(minLength: 8)
                Button(MoniLocalization.string(buttonTitle), action: action)
                    .buttonStyle(.borderedProminent)
                    .disabled(!isAvailable || !isActionEnabled || isScanning || isRunning)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
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
                catalogMetric("Available now", "21", MoniPalette.green)
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
        snapshot.unreadableItemCount
            + preferenceUnreadableItemCount
            + fileRepairSnapshot.unreadableItemCount
            + systemCleanupSnapshot.unreadableItemCount
    }

    private var dsStoreStatus: String {
        if settingsSnapshot.dsStoreKeysToEnable.isEmpty {
            return MoniLocalization.string("Enabled")
        }
        return MoniLocalization.format(
            "%@ settings pending",
            settingsSnapshot.dsStoreKeysToEnable.count.formatted()
        )
    }

    private var legacyOverrideStatus: String {
        if settingsSnapshot.legacyOverrides.isEmpty {
            return MoniLocalization.string("macOS defaults active")
        }
        return MoniLocalization.format(
            "%@ overrides found",
            settingsSnapshot.legacyOverrides.count.formatted()
        )
    }

    private var quarantineStatus: String {
        switch quarantineSnapshot.state {
        case .ready:
            quarantineSnapshot.entryCount == 0
                ? MoniLocalization.string("History is empty")
                : MoniLocalization.format("%@ records found", quarantineSnapshot.entryCount.formatted())
        case .unavailable:
            MoniLocalization.string("Unavailable")
        case .protected:
            MoniLocalization.string("Protected by whitelist")
        case .failed:
            MoniLocalization.string("Inspection failed")
        }
    }

    private var diskVerificationStatus: String {
        guard let outcome = diskVerificationReport?.result.outcome else {
            return MoniLocalization.string("Not verified")
        }
        return switch outcome {
        case .healthy: MoniLocalization.string("Verified healthy")
        case .attention: MoniLocalization.string("Needs attention")
        case .failed: MoniLocalization.string("Verification failed")
        case .unavailable: MoniLocalization.string("Unavailable")
        }
    }

    private var databaseMaintenanceIsAvailable: Bool {
        guard databaseSnapshot.availability == .ready else { return false }
        return databaseSnapshot.busyApplications.isEmpty
    }

    private var databaseMaintenanceStatus: String {
        switch databaseSnapshot.availability {
        case .unavailable:
            return MoniLocalization.string("Unavailable")
        case .processProbeFailed:
            return MoniLocalization.string("Application check failed")
        case .ready where !databaseSnapshot.busyApplications.isEmpty:
            return MoniLocalization.format(
                "Close %@ to continue",
                databaseSnapshot.busyApplications.joined(separator: ", ")
            )
        case .ready:
            let readyItems = databaseSnapshot.items.filter { $0.state == .ready }
            guard !readyItems.isEmpty else {
                return databaseSnapshot.items.isEmpty
                    ? MoniLocalization.string("No supported databases found")
                    : MoniLocalization.string("No databases need optimization")
            }
            let reclaimableBytes = readyItems.reduce(UInt64(0)) { $0 + $1.reclaimableBytes }
            return MoniLocalization.format(
                "%@ databases · %@ reclaimable",
                readyItems.count.formatted(),
                maintenanceBytes(reclaimableBytes)
            )
        }
    }

    private var spotlightRulesStatus: String {
        switch spotlightRulesSnapshot.state {
        case .ready:
            spotlightRulesSnapshot.orphanedRules.isEmpty
                ? MoniLocalization.string("Search rules are clean")
                : MoniLocalization.format(
                    "%@ orphan rules found",
                    spotlightRulesSnapshot.orphanedRules.count.formatted()
                )
        case .protected:
            MoniLocalization.string("Protected by whitelist")
        case .unavailable:
            MoniLocalization.string("Unavailable")
        case .incomplete:
            MoniLocalization.string("Application scan incomplete")
        case .failed:
            MoniLocalization.string("Inspection failed")
        }
    }

    private var loginItemsStatus: String {
        switch loginItemsSnapshot.state {
        case .ready where !loginItemsSnapshot.brokenItems.isEmpty:
            MoniLocalization.format(
                "%@ broken login items",
                loginItemsSnapshot.brokenItems.count.formatted()
            )
        case .ready:
            MoniLocalization.format(
                "%@ login items checked",
                loginItemsSnapshot.checkedCount.formatted()
            )
        case .unavailable:
            MoniLocalization.string("Unavailable")
        case .failed:
            MoniLocalization.string("Inspection failed")
        }
    }

    private var notificationStatus: String {
        switch notificationSnapshot.state {
        case .ready:
            MoniLocalization.format(
                "%@ database needs cleanup",
                maintenanceBytes(notificationSnapshot.sizeBytes)
            )
        case .healthy:
            MoniLocalization.format(
                "Healthy · %@",
                maintenanceBytes(notificationSnapshot.sizeBytes)
            )
        case .protected:
            MoniLocalization.string("Protected by whitelist")
        case .unavailable:
            MoniLocalization.string("Database unavailable")
        case .failed:
            MoniLocalization.string("Inspection failed")
        }
    }

    private var coreDuetStatus: String {
        switch coreDuetSnapshot.state {
        case .ready:
            MoniLocalization.format(
                "%@ database needs cleanup",
                maintenanceBytes(coreDuetSnapshot.totalSizeBytes)
            )
        case .healthy:
            MoniLocalization.format(
                "Healthy · %@",
                maintenanceBytes(coreDuetSnapshot.totalSizeBytes)
            )
        case .protected:
            MoniLocalization.string("Protected by whitelist")
        case .unavailable:
            MoniLocalization.string("Database unavailable")
        case .failed:
            MoniLocalization.string("Inspection failed")
        }
    }

    private var systemMaintenanceStatus: String {
        switch systemMaintenanceSnapshot.spotlightStatus {
        case .enabled:
            MoniLocalization.string("Spotlight indexing enabled")
        case .disabled:
            MoniLocalization.string("Spotlight indexing disabled")
        case .unavailable:
            MoniLocalization.string("Unavailable")
        case .failed:
            MoniLocalization.string("Spotlight check failed")
        }
    }

    private var networkStackStatus: String {
        switch networkStackState {
        case .optimal:
            MoniLocalization.string("Network stack is healthy")
        case .needsRefresh:
            MoniLocalization.string("Network issue detected")
        case .activeVPN:
            MoniLocalization.string("Active VPN detected")
        case .unavailable:
            MoniLocalization.string("Unavailable")
        case .failed:
            MoniLocalization.string("Inspection failed")
        }
    }

    private var networkStackButtonTitle: String {
        switch networkStackState {
        case .needsRefresh: MoniLocalization.string("Review Refresh")
        case .optimal: MoniLocalization.string("No action needed")
        case .activeVPN: MoniLocalization.string("VPN active")
        case .unavailable, .failed: MoniLocalization.string("Unavailable")
        }
    }

    private var networkStackIsAvailable: Bool {
        networkStackState != .unavailable && networkStackState != .failed
    }

    private var permissionRepairStatus: String {
        switch permissionRepairState {
        case .optimal: MoniLocalization.string("User permissions are healthy")
        case .needsRepair: MoniLocalization.string("Permission issue detected")
        case .unavailable: MoniLocalization.string("Unavailable")
        }
    }

    private var permissionRepairButtonTitle: String {
        switch permissionRepairState {
        case .optimal: MoniLocalization.string("No action needed")
        case .needsRepair: MoniLocalization.string("Review Repair")
        case .unavailable: MoniLocalization.string("Unavailable")
        }
    }

    private var spotlightOptimizationStatus: String {
        switch spotlightOptimizationState {
        case .optimal: MoniLocalization.string("Spotlight search is responsive")
        case .slow: MoniLocalization.string("Slow searches detected")
        case .rebuilding: MoniLocalization.string("Index rebuild in progress")
        case .indexingDisabled: MoniLocalization.string("Spotlight indexing disabled")
        case .batteryPower: MoniLocalization.string("Connect power to inspect speed")
        case .unavailable: MoniLocalization.string("Unavailable")
        case .failed: MoniLocalization.string("Inspection failed")
        }
    }

    private var spotlightOptimizationButtonTitle: String {
        switch spotlightOptimizationState {
        case .slow: MoniLocalization.string("Review Rebuild")
        case .optimal, .rebuilding: MoniLocalization.string("No action needed")
        case .indexingDisabled: MoniLocalization.string("Indexing disabled")
        case .batteryPower: MoniLocalization.string("Power required")
        case .unavailable, .failed: MoniLocalization.string("Unavailable")
        }
    }

    private var spotlightOptimizationIsAvailable: Bool {
        spotlightOptimizationState != .unavailable && spotlightOptimizationState != .failed
    }

    private var periodicMaintenanceStatus: String {
        switch periodicMaintenanceSnapshot.state {
        case .current:
            if let ageDays = periodicMaintenanceSnapshot.ageDays {
                return MoniLocalization.format("Current · %@d ago", ageDays.formatted())
            }
            return MoniLocalization.string("Current")
        case .stale:
            if let ageDays = periodicMaintenanceSnapshot.ageDays {
                return MoniLocalization.format("Stale · %@d ago", ageDays.formatted())
            }
            return MoniLocalization.string("Maintenance is stale")
        case .missingLog:
            return MoniLocalization.string("Maintenance log missing")
        case .unavailable:
            return MoniLocalization.string("Unavailable on this macOS version")
        case .failed:
            return MoniLocalization.string("Inspection failed")
        }
    }

    private var periodicMaintenanceButtonTitle: String {
        switch periodicMaintenanceSnapshot.state {
        case .stale, .missingLog: MoniLocalization.string("Review Maintenance")
        case .current: MoniLocalization.string("No action needed")
        case .unavailable, .failed: MoniLocalization.string("Unavailable")
        }
    }

    private var tartCacheStatus: String {
        switch tartCacheSnapshot.state {
        case .ready:
            MoniLocalization.format("%@ available", maintenanceBytes(tartCacheSnapshot.sizeBytes))
        case .healthy:
            MoniLocalization.string("No cache to prune")
        case .protected:
            MoniLocalization.string("Protected by whitelist")
        case .busy:
            MoniLocalization.string("Tart is running")
        case .unavailable:
            MoniLocalization.string("Tart command unavailable")
        case .failed:
            MoniLocalization.string("Inspection failed")
        }
    }

    private var tartCacheButtonTitle: String {
        switch tartCacheSnapshot.state {
        case .ready: MoniLocalization.string("Review Prune")
        case .healthy: MoniLocalization.string("No action needed")
        case .protected: MoniLocalization.string("Protected")
        case .busy: MoniLocalization.string("Close Tart first")
        case .unavailable, .failed: MoniLocalization.string("Unavailable")
        }
    }

    private var timeMachineSnapshotStatus: String {
        switch timeMachineSnapshotReport.state {
        case .ready:
            if !timeMachineSnapshotReport.incompleteBackups.isEmpty {
                let size = timeMachineSnapshotReport.incompleteBackups.reduce(UInt64(0)) { partial, item in
                    let (sum, overflow) = partial.addingReportingOverflow(item.sizeBytes)
                    return overflow ? UInt64.max : sum
                }
                return MoniLocalization.format(
                    "%@ incomplete backups · %@",
                    timeMachineSnapshotReport.incompleteBackups.count.formatted(),
                    maintenanceBytes(size)
                )
            }
            return MoniLocalization.format(
                "%@ local snapshots",
                timeMachineSnapshotReport.snapshotCount.formatted()
            )
        case .none:
            return timeMachineSnapshotReport.unreadableItemCount > 0
                ? MoniLocalization.string("Backup scan incomplete")
                : MoniLocalization.string("No snapshots or incomplete backups")
        case .busy:
            return MoniLocalization.string("Backup in progress")
        case .notConfigured:
            return MoniLocalization.string("Time Machine not configured")
        case .unavailable:
            return MoniLocalization.string("Time Machine unavailable")
        case .failed:
            return MoniLocalization.string("Inspection failed")
        }
    }

    private var timeMachineCleanupButtonTitle: String {
        if !timeMachineSnapshotReport.incompleteBackups.isEmpty {
            return MoniLocalization.string("Review Cleanup")
        }
        switch timeMachineSnapshotReport.state {
        case .ready:
            return MoniLocalization.string("Report only")
        case .none:
            return MoniLocalization.string("No action needed")
        case .busy:
            return MoniLocalization.string("Backup in progress")
        case .notConfigured:
            return MoniLocalization.string("Not configured")
        case .unavailable, .failed:
            return MoniLocalization.string("Unavailable")
        }
    }

    private var systemCleanupStatus: String {
        switch systemCleanupSnapshot.state {
        case .notScanned:
            return MoniLocalization.string("Administrator scan required")
        case .ready:
            let total = systemCleanupSnapshot.items.reduce(UInt64(0)) { partial, item in
                let (sum, overflow) = partial.addingReportingOverflow(item.sizeBytes)
                return overflow ? UInt64.max : sum
            }
            return MoniLocalization.format(
                "%@ files · %@",
                systemCleanupSnapshot.items.count.formatted(),
                maintenanceBytes(total)
            )
        case .empty:
            if let notice = systemCleanupSnapshot.activePowerLogNotice {
                return MoniLocalization.format(
                    "Active database kept · %@",
                    maintenanceBytes(notice.sizeBytes)
                )
            }
            return MoniLocalization.string("No old system files")
        case .unavailable:
            return MoniLocalization.string("Unavailable")
        case .cancelled:
            return MoniLocalization.string("Scan cancelled")
        case .failed:
            return MoniLocalization.string("Scan failed")
        }
    }

    private var systemCleanupButtonTitle: String {
        switch systemCleanupSnapshot.state {
        case .ready:
            return MoniLocalization.string("Review Cleanup")
        case .empty:
            return MoniLocalization.string("Rescan")
        case .notScanned, .cancelled, .failed:
            return MoniLocalization.string("Start Scan")
        case .unavailable:
            return MoniLocalization.string("Unavailable")
        }
    }

    private func scanSystemCleanup() async {
        isRunning = true
        let result = await SystemCleanupService.scan()
        isRunning = false
        systemCleanupSnapshot = result
        switch result.state {
        case .ready:
            await prepareSystemCleanup()
        case .empty:
            if let notice = result.activePowerLogNotice {
                resultMessage = MoniLocalization.format(
                    "The active power telemetry database is %@ and was kept.",
                    maintenanceBytes(notice.sizeBytes)
                )
            } else {
                resultMessage = MoniLocalization.string("No old system caches or logs were found.")
            }
        case .cancelled:
            resultMessage = MoniLocalization.string("System cleanup scan was cancelled.")
        case .unavailable:
            resultMessage = MoniLocalization.string("System cleanup scan is unavailable.")
        case .failed:
            resultMessage = MoniLocalization.string("System cleanup scan did not complete.")
        case .notScanned:
            break
        }
    }

    private func prepareSystemCleanup() async {
        let plan = await SystemCleanupService.previewCleanup(
            items: systemCleanupSnapshot.items,
            activePowerLogNotice: systemCleanupSnapshot.activePowerLogNotice
        )
        if plan.cleanupPlan.candidates.isEmpty {
            if let notice = systemCleanupSnapshot.activePowerLogNotice {
                resultMessage = MoniLocalization.format(
                    "No scanned system files can be cleaned. The active power telemetry database is %@ and was kept.",
                    maintenanceBytes(notice.sizeBytes)
                )
            } else {
                resultMessage = MoniLocalization.string("No scanned system files can be cleaned.")
            }
        } else {
            pendingSystemCleanup = plan
        }
    }

    private func executeSystemCleanup(_ plan: SystemCleanupPlan) async {
        isRunning = true
        let result = await SystemCleanupService.executeCleanup(plan)
        isRunning = false
        monitor.refresh(forceSlowMetrics: true)

        let trashedPaths = Set(result.trashedPaths)
        let remainingItems = systemCleanupSnapshot.items.filter {
            !trashedPaths.contains($0.path)
        }
        systemCleanupSnapshot = SystemCleanupSnapshot(
            state: remainingItems.isEmpty ? .empty : .ready,
            items: remainingItems,
            unreadableItemCount: systemCleanupSnapshot.unreadableItemCount,
            activePowerLogNotice: systemCleanupSnapshot.activePowerLogNotice
        )

        var parts: [String] = []
        if !result.trashedPaths.isEmpty {
            parts.append(MoniLocalization.format(
                "Moved %@ system files to Trash.",
                result.trashedPaths.count.formatted()
            ))
        }
        if !result.rejectedItems.isEmpty {
            parts.append(MoniLocalization.format(
                "%@ system files were protected or changed.",
                result.rejectedItems.count.formatted()
            ))
        }
        if !result.failedPaths.isEmpty {
            parts.append(MoniLocalization.format(
                "%@ system files could not be moved.",
                result.failedPaths.count.formatted()
            ))
        }
        if parts.isEmpty {
            parts.append(MoniLocalization.string("No system files needed cleanup."))
        }
        resultMessage = parts.joined(separator: " ")
    }

    private func prepareTimeMachineCleanup() async {
        let plan = await TimeMachineSnapshotService.previewCleanup(
            items: timeMachineSnapshotReport.incompleteBackups
        )
        if plan.cleanupPlan.candidates.isEmpty {
            resultMessage = MoniLocalization.string("No incomplete backups can be removed.")
        } else {
            pendingTimeMachineCleanup = plan
        }
    }

    private func executeTimeMachineCleanup(_ plan: TimeMachineBackupCleanupPlan) async {
        isRunning = true
        let result = await TimeMachineSnapshotService.executeCleanup(plan)
        await scan()
        isRunning = false
        monitor.refresh(forceSlowMetrics: true)

        var parts: [String] = []
        if !result.removedPaths.isEmpty {
            parts.append(MoniLocalization.format(
                "Removed %@ incomplete backups.",
                result.removedPaths.count.formatted()
            ))
        }
        if !result.rejectedItems.isEmpty {
            parts.append(MoniLocalization.format(
                "%@ backups were protected or changed.",
                result.rejectedItems.count.formatted()
            ))
        }
        if !result.failedPaths.isEmpty {
            parts.append(MoniLocalization.format(
                "%@ backups could not be removed.",
                result.failedPaths.count.formatted()
            ))
        }
        if parts.isEmpty {
            parts.append(MoniLocalization.string("No incomplete backups needed removal."))
        }
        resultMessage = parts.joined(separator: " ")
    }

    private func scan() async {
        isScanning = true
        async let finderResult = MaintenanceService.scanFinderMaintenance()
        async let preferenceResult = MaintenanceService.scanBrokenPreferences()
        async let repairResult = MaintenanceService.scanFileRepairs()
        async let settingsResult = MaintenanceSettingsService.scan()
        async let quarantineResult = MaintenanceDiagnosticsService.scanQuarantineHistory()
        async let databaseResult = DatabaseMaintenanceService.scan()
        async let spotlightRulesResult = SpotlightRulesMaintenanceService.scan()
        async let loginItemsResult = LoginItemsAuditService.scan()
        async let notificationResult = NotificationMaintenanceService.scan()
        async let coreDuetResult = CoreDuetMaintenanceService.scan()
        async let systemMaintenanceResult = AdministratorMaintenanceService.scanSystemMaintenance()
        async let networkStackResult = AdministratorMaintenanceService.scanNetworkStack()
        async let permissionRepairResult = AdministratorMaintenanceService.scanPermissionRepair()
        async let spotlightOptimizationResult = AdministratorMaintenanceService.scanSpotlightOptimization()
        async let periodicMaintenanceResult = AdministratorMaintenanceService.scanPeriodicMaintenance()
        async let tartCacheResult = TartCacheMaintenanceService.scan()
        async let timeMachineSnapshotResult = TimeMachineSnapshotService.scan()
        let (finder, preferences, repairs, settings, quarantine, databases, spotlightRules, loginItems, notifications, coreDuet, systemMaintenance, networkStack, permissionRepair, spotlightOptimization, periodicMaintenance, tartCache, timeMachineSnapshots) = await (
            finderResult, preferenceResult, repairResult, settingsResult, quarantineResult,
            databaseResult, spotlightRulesResult, loginItemsResult, notificationResult, coreDuetResult,
            systemMaintenanceResult, networkStackResult, permissionRepairResult,
            spotlightOptimizationResult, periodicMaintenanceResult, tartCacheResult,
            timeMachineSnapshotResult
        )
        guard !Task.isCancelled else { return }
        snapshot = finder
        brokenPreferencePaths = preferences.paths
        preferenceUnreadableItemCount = preferences.unreadableItemCount
        fileRepairSnapshot = repairs
        settingsSnapshot = settings
        quarantineSnapshot = quarantine
        databaseSnapshot = databases
        spotlightRulesSnapshot = spotlightRules
        loginItemsSnapshot = loginItems
        notificationSnapshot = notifications
        coreDuetSnapshot = coreDuet
        systemMaintenanceSnapshot = systemMaintenance
        networkStackState = networkStack
        permissionRepairState = permissionRepair
        spotlightOptimizationState = spotlightOptimization
        periodicMaintenanceSnapshot = periodicMaintenance
        tartCacheSnapshot = tartCache
        timeMachineSnapshotReport = timeMachineSnapshots
        isScanning = false
    }

    private func prepare(_ action: FinderMaintenanceAction, paths: [String]) async {
        let plan = await CleanupService.shared.preview(paths: paths, scope: .maintenance)
        pendingAction = PendingMaintenanceAction(action: action, plan: plan)
    }

    private func execute(_ pending: PendingMaintenanceAction) async {
        isRunning = true
        if pending.action == .launchAgents {
            await MaintenanceService.unloadUserLaunchAgents(pending.plan.candidates)
        }
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
            parts.append(MoniLocalization.string(noChangeMessage(for: pending.action)))
        }

        await scan()
        isRunning = false
        monitor.refresh(forceSlowMetrics: true)
        resultMessage = parts.joined(separator: " ")
    }

    private func noChangeMessage(for action: FinderMaintenanceAction) -> String {
        switch action {
        case .finderCache: "Finder caches did not need cleanup."
        case .savedApplicationStates: "No old application states needed cleanup."
        case .brokenPreferences: "No damaged preference files needed repair."
        case .sharedFileLists: "Shared file lists are healthy."
        case .launchAgents: "Launch Agents are healthy."
        }
    }

    private func rebuildLaunchServices() async {
        isRunning = true
        let result = await MaintenanceSettingsService.rebuildLaunchServices()
        isRunning = false
        if result.unavailable {
            resultMessage = MoniLocalization.string("LaunchServices repair is unavailable.")
        } else if result.failedCount > 0 {
            resultMessage = MoniLocalization.string("LaunchServices could not be rebuilt.")
        } else {
            resultMessage = MoniLocalization.string("LaunchServices and file associations were rebuilt.")
        }
    }

    private func enableDSStorePrevention() async {
        isRunning = true
        let result = await MaintenanceSettingsService.enableDSStorePrevention()
        settingsSnapshot = await MaintenanceSettingsService.scan()
        isRunning = false
        if result.failedCount > 0 {
            resultMessage = MoniLocalization.format(
                "%@ Finder settings could not be updated.",
                result.failedCount.formatted()
            )
        } else if result.changedCount > 0 {
            resultMessage = MoniLocalization.string("Finder .DS_Store prevention is enabled for network and USB volumes.")
        } else {
            resultMessage = MoniLocalization.string("Finder .DS_Store prevention was already enabled or protected by the whitelist.")
        }
    }

    private func removeLegacyOverrides(_ overrides: [LegacySystemOverride]) async {
        isRunning = true
        let result = await MaintenanceSettingsService.removeLegacyOverrides(overrides)
        settingsSnapshot = await MaintenanceSettingsService.scan()
        isRunning = false
        if result.failedCount > 0 {
            resultMessage = MoniLocalization.format(
                "%@ legacy overrides could not be removed.",
                result.failedCount.formatted()
            )
        } else if result.changedCount > 0 {
            resultMessage = MoniLocalization.format(
                "Removed %@ legacy overrides and restored macOS defaults.",
                result.changedCount.formatted()
            )
        } else {
            resultMessage = MoniLocalization.string("No active unprotected legacy overrides remained.")
        }
    }

    private func clearQuarantineHistory() async {
        isRunning = true
        let result = await MaintenanceDiagnosticsService.clearQuarantineHistory()
        quarantineSnapshot = await MaintenanceDiagnosticsService.scanQuarantineHistory()
        isRunning = false
        switch result.state {
        case .ready where result.removedCount > 0:
            resultMessage = MoniLocalization.format(
                "Cleared %@ Gatekeeper download records.",
                result.removedCount.formatted()
            )
        case .ready:
            resultMessage = MoniLocalization.string("Gatekeeper download history was already empty.")
        case .protected:
            resultMessage = MoniLocalization.string("Gatekeeper history is protected by the cleanup whitelist.")
        case .unavailable:
            resultMessage = MoniLocalization.string("Gatekeeper history cleanup is unavailable.")
        case .failed:
            resultMessage = MoniLocalization.string("Gatekeeper download history could not be cleared.")
        }
    }

    private func verifyStartupVolume() async {
        isRunning = true
        let result = await MaintenanceDiagnosticsService.verifyStartupVolume()
        isRunning = false
        diskVerificationReport = DiskVerificationReport(result: result)
    }

    private func optimizeDatabases(_ items: [DatabaseMaintenanceItem]) async {
        let readyItems = items.filter { $0.state == .ready }
        isRunning = true
        let result = await DatabaseMaintenanceService.optimize(readyItems)
        databaseSnapshot = await DatabaseMaintenanceService.scan()
        isRunning = false

        var parts: [String] = []
        if result.optimizedCount > 0 {
            parts.append(MoniLocalization.format(
                "Optimized %@ databases.",
                result.optimizedCount.formatted()
            ))
        }
        if result.skippedCount > 0 {
            parts.append(MoniLocalization.format(
                "%@ databases were protected, changed, or became busy.",
                result.skippedCount.formatted()
            ))
        }
        if result.failedCount > 0 {
            parts.append(MoniLocalization.format(
                "%@ databases could not be optimized.",
                result.failedCount.formatted()
            ))
        }
        if parts.isEmpty {
            parts.append(MoniLocalization.string("No databases needed optimization."))
        }
        monitor.refresh(forceSlowMetrics: true)
        resultMessage = parts.joined(separator: " ")
    }

    private func removeSpotlightRules(_ rules: [String]) async {
        isRunning = true
        let result = await SpotlightRulesMaintenanceService.remove(rules)
        spotlightRulesSnapshot = await SpotlightRulesMaintenanceService.scan()
        isRunning = false

        if result.failedCount > 0 {
            resultMessage = MoniLocalization.string("Spotlight search rules could not be updated.")
        } else if result.removedCount > 0 {
            resultMessage = MoniLocalization.format(
                "Removed %@ orphan Spotlight rules.",
                result.removedCount.formatted()
            )
        } else if result.skippedCount > 0 {
            resultMessage = MoniLocalization.string("Spotlight rules changed or the application scan became incomplete.")
        } else {
            resultMessage = MoniLocalization.string("Spotlight search rules were already clean.")
        }
    }

    private func cleanNotifications() async {
        isRunning = true
        let result = await NotificationMaintenanceService.clean(notificationSnapshot)
        notificationSnapshot = await NotificationMaintenanceService.scan()
        isRunning = false

        if result.cleaned {
            resultMessage = MoniLocalization.string("Old delivered notifications were removed and the database was compacted.")
        } else if result.failed {
            resultMessage = MoniLocalization.string("Notification cleanup failed because the database was busy, locked, or incompatible.")
        } else {
            resultMessage = MoniLocalization.string("Notification cleanup was skipped because the database changed or became protected.")
        }
    }

    private func cleanCoreDuetData() async {
        isRunning = true
        let result = await CoreDuetMaintenanceService.clean(coreDuetSnapshot)
        coreDuetSnapshot = await CoreDuetMaintenanceService.scan()
        isRunning = false

        var parts: [String] = []
        if result.databaseCleaned {
            parts.append(MoniLocalization.string("Usage records older than 90 days were removed and the database was compacted."))
        }
        if result.trashedSidecarCount > 0 {
            parts.append(MoniLocalization.format(
                "Moved %@ database sidecar files to Trash.",
                result.trashedSidecarCount.formatted()
            ))
        }
        if result.failedSidecarCount > 0 {
            parts.append(MoniLocalization.format(
                "%@ database sidecar files could not be moved.",
                result.failedSidecarCount.formatted()
            ))
        }
        if result.databaseFailed {
            parts.append(MoniLocalization.string("Usage data cleanup failed because the database was busy, locked, or incompatible."))
        } else if result.skipped {
            parts.append(MoniLocalization.string("Usage data cleanup was skipped because the database changed or became protected."))
        }
        resultMessage = parts.isEmpty
            ? MoniLocalization.string("No usage data needed cleanup.")
            : parts.joined(separator: " ")
    }

    private func runSystemMaintenance() async {
        isRunning = true
        let result = await AdministratorMaintenanceService.runSystemMaintenance()
        systemMaintenanceSnapshot = SystemMaintenanceSnapshot(
            spotlightStatus: result.spotlightStatus
        )
        isRunning = false

        var parts: [String] = []
        parts.append(result.dnsCacheFlushed
            ? MoniLocalization.string("DNS cache was flushed and mDNSResponder was restarted.")
            : MoniLocalization.string("DNS refresh was not completed. Administrator approval may have been cancelled."))
        switch result.spotlightStatus {
        case .enabled:
            parts.append(MoniLocalization.string("Spotlight indexing is enabled."))
        case .disabled:
            parts.append(MoniLocalization.string("Spotlight indexing is disabled."))
        case .unavailable, .failed:
            parts.append(MoniLocalization.string("Spotlight status could not be verified."))
        }
        resultMessage = parts.joined(separator: " ")
    }

    private func refreshNetworkCache() async {
        isRunning = true
        let result = await AdministratorMaintenanceService.refreshNetworkCache()
        isRunning = false
        resultMessage = result.refreshed
            ? MoniLocalization.string("Network cache was refreshed and mDNSResponder was restarted.")
            : MoniLocalization.string("Network cache refresh was not completed. Administrator approval may have been cancelled.")
    }

    private func refreshNetworkStack() async {
        isRunning = true
        let outcome = await AdministratorMaintenanceService.refreshNetworkStack()
        networkStackState = await AdministratorMaintenanceService.scanNetworkStack()
        isRunning = false

        switch outcome {
        case .alreadyOptimal:
            resultMessage = MoniLocalization.string("The network stack is already healthy.")
        case .activeVPN:
            resultMessage = MoniLocalization.string("Network stack refresh was skipped because an active VPN was detected.")
        case .unavailable:
            resultMessage = MoniLocalization.string("Network stack refresh is unavailable on this system.")
        case .inspectionFailed:
            resultMessage = MoniLocalization.string("Network stack refresh was skipped because network health could not be verified.")
        case .authorizationCancelled:
            resultMessage = MoniLocalization.string("Network stack refresh was not completed. Administrator approval may have been cancelled.")
        case let .applied(routeFlushed, arpFlushed):
            var parts: [String] = []
            parts.append(routeFlushed
                ? MoniLocalization.string("The network routing table was refreshed.")
                : MoniLocalization.string("The network routing table could not be refreshed."))
            parts.append(arpFlushed
                ? MoniLocalization.string("The ARP cache was cleared.")
                : MoniLocalization.string("The ARP cache could not be cleared."))
            resultMessage = parts.joined(separator: " ")
        }
    }

    private func repairUserPermissions() async {
        isRunning = true
        let outcome = await AdministratorMaintenanceService.repairUserPermissions()
        permissionRepairState = await AdministratorMaintenanceService.scanPermissionRepair()
        isRunning = false

        switch outcome {
        case .alreadyOptimal:
            resultMessage = MoniLocalization.string("User directory permissions are already healthy.")
        case .unavailable:
            resultMessage = MoniLocalization.string("Permission repair is unavailable on this system.")
        case .repaired:
            resultMessage = MoniLocalization.string("User directory permissions were repaired.")
        case .notCompleted:
            resultMessage = MoniLocalization.string("Permission repair was not completed. Administrator approval may have been cancelled, or diskutil reported an error.")
        }
    }

    private func optimizeSpotlight() async {
        isRunning = true
        let outcome = await AdministratorMaintenanceService.optimizeSpotlight()
        if case .rebuildStarted = outcome {
            spotlightOptimizationState = .rebuilding
        } else {
            spotlightOptimizationState = await AdministratorMaintenanceService.scanSpotlightOptimization()
        }
        isRunning = false

        switch outcome {
        case .alreadyOptimal:
            resultMessage = MoniLocalization.string("The Spotlight index is already responsive.")
        case .indexingDisabled:
            resultMessage = MoniLocalization.string("Spotlight optimization was skipped because indexing is disabled.")
        case .batteryPower:
            resultMessage = MoniLocalization.string("Spotlight optimization was skipped while the Mac is using battery power.")
        case .unavailable:
            resultMessage = MoniLocalization.string("Spotlight optimization is unavailable on this system.")
        case .inspectionFailed:
            resultMessage = MoniLocalization.string("Spotlight optimization was skipped because index health could not be verified.")
        case .rebuildStarted:
            resultMessage = MoniLocalization.string("The Spotlight index rebuild started and will continue in the background.")
        case .notCompleted:
            resultMessage = MoniLocalization.string("Spotlight index rebuild was not started. Administrator approval may have been cancelled, or mdutil reported an error.")
        }
    }

    private func runPeriodicMaintenance() async {
        isRunning = true
        let outcome = await AdministratorMaintenanceService.runPeriodicMaintenance()
        periodicMaintenanceSnapshot = await AdministratorMaintenanceService.scanPeriodicMaintenance()
        isRunning = false

        switch outcome {
        case .alreadyCurrent:
            resultMessage = MoniLocalization.string("Periodic maintenance is already current.")
        case .unavailable:
            resultMessage = MoniLocalization.string("Periodic maintenance is unavailable on this macOS version.")
        case .inspectionFailed:
            resultMessage = MoniLocalization.string("Periodic maintenance was skipped because the daily log could not be inspected.")
        case .triggered:
            resultMessage = MoniLocalization.string("Daily, weekly, and monthly maintenance scripts completed.")
        case .notCompleted:
            resultMessage = MoniLocalization.string("Periodic maintenance was not completed. Administrator approval may have been cancelled, or a system script reported an error.")
        }
    }

    private func pruneTartCaches() async {
        isRunning = true
        let outcome = await TartCacheMaintenanceService.prune()
        tartCacheSnapshot = await TartCacheMaintenanceService.scan()
        isRunning = false

        switch outcome {
        case let .pruned(reclaimedBytes):
            resultMessage = MoniLocalization.format(
                "Tart cache pruning completed and reclaimed %@.",
                maintenanceBytes(reclaimedBytes)
            )
        case .noAction:
            resultMessage = MoniLocalization.string("No Tart cache entries needed pruning.")
        case .protected:
            resultMessage = MoniLocalization.string("Tart cache pruning was skipped because the cache is protected by the whitelist.")
        case .busy:
            resultMessage = MoniLocalization.string("Tart cache pruning was skipped because Tart is running.")
        case .unavailable:
            resultMessage = MoniLocalization.string("Tart cache pruning is unavailable because the Tart command could not be found.")
        case .failed:
            resultMessage = MoniLocalization.string("Tart cache pruning did not complete successfully.")
        }
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
            } else if pending.action == .launchAgents {
                Label("Listed LaunchAgent jobs will be unloaded before their files are moved.", systemImage: "stop.circle")
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
        case .sharedFileLists:
            MoniLocalization.string("Listed malformed shared file lists will be moved to Trash. Finder can recreate them when needed.")
        case .launchAgents:
            MoniLocalization.string("Listed LaunchAgents point to missing executables and will be moved to Trash after unloading.")
        }
    }

    private var confirmationTitle: String {
        switch pending.action {
        case .finderCache: "Refresh Finder caches?"
        case .savedApplicationStates: "Clean old application states?"
        case .brokenPreferences: "Repair broken preferences?"
        case .sharedFileLists: "Repair shared file lists?"
        case .launchAgents: "Clean broken LaunchAgents?"
        }
    }

    private var emptyDescription: String {
        switch pending.action {
        case .finderCache: "Finder services can still be refreshed."
        case .savedApplicationStates: "No saved application states older than 30 days were found."
        case .brokenPreferences: "No damaged third-party preference files were found."
        case .sharedFileLists: "No damaged shared file lists were found."
        case .launchAgents: "No LaunchAgents with missing executables were found."
        }
    }
}

private struct DatabaseMaintenanceConfirmationView: View {
    let items: [DatabaseMaintenanceItem]
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Optimize application databases?")
                    .font(.system(size: 18, weight: .bold))
                Text("Only databases marked Ready will be compacted. Moni checks database integrity again immediately before optimization.")
                    .font(.system(size: 12))
                    .foregroundStyle(MoniPalette.foregroundTertiary)
            }

            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 8) {
                                Text(item.applicationName)
                                    .font(.system(size: 12.5, weight: .semibold))
                                Spacer(minLength: 8)
                                Text(MoniLocalization.string(stateTitle(for: item.state)))
                                    .font(.system(size: 10.5, weight: .bold))
                                    .foregroundStyle(stateColor(for: item.state))
                            }
                            Text(item.path)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(MoniPalette.foregroundTertiary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                            HStack(spacing: 12) {
                                Text(MoniLocalization.format("Size %@", maintenanceBytes(item.sizeBytes)))
                                if item.reclaimableBytes > 0 {
                                    Text(MoniLocalization.format(
                                        "Reclaimable %@",
                                        maintenanceBytes(item.reclaimableBytes)
                                    ))
                                }
                            }
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(MoniPalette.foregroundSecondary)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(MoniPalette.insetSecondary)
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }
                }
                .padding(1)
            }
            .frame(maxHeight: 300)

            Label("Mail, Safari, and Messages must remain closed until optimization finishes.", systemImage: "exclamationmark.triangle")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(MoniPalette.orange)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Optimize Databases", role: .destructive, action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .disabled(readyItems.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 620)
    }

    private var readyItems: [DatabaseMaintenanceItem] {
        items.filter { $0.state == .ready }
    }

    private func stateTitle(for state: DatabaseMaintenanceState) -> String {
        switch state {
        case .ready: "Ready"
        case .optimal: "Already optimized"
        case .oversized: "Over 100 MB"
        case .protected: "Protected by whitelist"
        case .failed: "Inspection failed"
        }
    }

    private func stateColor(for state: DatabaseMaintenanceState) -> Color {
        switch state {
        case .ready: MoniPalette.green
        case .optimal: MoniPalette.foregroundSecondary
        case .oversized, .protected: MoniPalette.orange
        case .failed: MoniPalette.red
        }
    }
}

private struct SpotlightRulesConfirmationView: View {
    let rules: [String]
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Remove orphan Spotlight rules?")
                    .font(.system(size: 18, weight: .bold))
                Text("Only the listed third-party bundle identifiers will be removed from Spotlight search settings. The application scan runs again before the change.")
                    .font(.system(size: 12))
                    .foregroundStyle(MoniPalette.foregroundTertiary)
            }

            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(rules, id: \.self) { rule in
                        Label {
                            Text(rule)
                                .font(.system(size: 11.5, design: .monospaced))
                                .textSelection(.enabled)
                        } icon: {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(MoniPalette.orange)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(MoniPalette.insetSecondary)
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }
                }
                .padding(1)
            }
            .frame(maxHeight: 280)

            Label("System rules, Apple rules, malformed entries, and identifiers with uncertain application status are always kept.", systemImage: "checkmark.shield")
                .font(.system(size: 11.5))
                .foregroundStyle(MoniPalette.foregroundSecondary)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Remove Rules", role: .destructive, action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .disabled(rules.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 620)
    }
}

private struct LoginItemsAuditView: View {
    let items: [BrokenLoginItem]
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Broken Login Items")
                    .font(.system(size: 18, weight: .bold))
                Text("These login items could not be matched to an installed application or executable.")
                    .font(.system(size: 12))
                    .foregroundStyle(MoniPalette.foregroundTertiary)
            }

            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 5) {
                            Label(item.name, systemImage: "exclamationmark.triangle")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(MoniPalette.orange)
                            Text(item.path.isEmpty
                                ? MoniLocalization.string("No path was reported by macOS")
                                : item.path)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(MoniPalette.foregroundTertiary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(MoniPalette.insetSecondary)
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }
                }
                .padding(1)
            }
            .frame(maxHeight: 280)

            Label("Review and remove stale entries in System Settings > General > Login Items. Moni does not remove login items automatically.", systemImage: "gearshape")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(MoniPalette.foregroundSecondary)

            HStack {
                Spacer()
                Button("Close", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620)
    }
}

private struct LegacyOverrideConfirmationView: View {
    let overrides: [LegacySystemOverride]
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Remove legacy overrides?")
                    .font(.system(size: 18, weight: .bold))
                Text("Only the listed preference keys will be deleted. macOS will resume its default behavior.")
                    .font(.system(size: 12))
                    .foregroundStyle(MoniPalette.foregroundTertiary)
            }

            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(overrides) { override in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(MoniLocalization.string(override.titleKey))
                                .font(.system(size: 12.5, weight: .semibold))
                            Text(override.key)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(MoniPalette.orange)
                            Text(override.preferencePath)
                                .font(.system(size: 10.5))
                                .foregroundStyle(MoniPalette.foregroundTertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(MoniPalette.insetSecondary)
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }
                }
            }
            .frame(maxHeight: 280)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Restore Defaults", role: .destructive, action: onConfirm)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 580)
    }
}

private struct TimeMachineBackupCleanupConfirmationView: View {
    let plan: TimeMachineBackupCleanupPlan
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Remove incomplete backups?")
                    .font(.system(size: 18, weight: .bold))
                Text("Time Machine will permanently remove only the verified incomplete backups below. Local snapshots are report-only.")
                    .font(.system(size: 12))
                    .foregroundStyle(MoniPalette.foregroundTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(readyItems) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(item.name)
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                Text(maintenanceBytes(item.sizeBytes))
                                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                                    .foregroundStyle(MoniPalette.orange)
                            }
                            Text(item.path)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(MoniPalette.foregroundTertiary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                            Text(relativeDate(item.modifiedDate))
                                .font(.system(size: 10.5))
                                .foregroundStyle(MoniPalette.foregroundTertiary)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(MoniPalette.insetSecondary)
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }
                }
                .padding(1)
            }
            .frame(maxHeight: 300)

            Label(
                "macOS may request administrator approval. Every backup is rechecked immediately before tmutil receives its path.",
                systemImage: "checkmark.shield"
            )
            .font(.system(size: 11.5))
            .foregroundStyle(MoniPalette.foregroundSecondary)

            HStack {
                Text(MoniLocalization.format(
                    "%@ backups · %@",
                    readyItems.count.formatted(),
                    maintenanceBytes(totalSize)
                ))
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(MoniPalette.foregroundSecondary)
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Remove Backups", role: .destructive, action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .disabled(readyItems.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 640)
    }

    private var readyItems: [TimeMachineIncompleteBackupItem] {
        let paths = Set(plan.cleanupPlan.candidates.map(\.path))
        return plan.items.filter { paths.contains($0.path) }
    }

    private var totalSize: UInt64 {
        readyItems.reduce(0) { partial, item in
            let (sum, overflow) = partial.addingReportingOverflow(item.sizeBytes)
            return overflow ? UInt64.max : sum
        }
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = MoniLocalization.currentLanguage.locale
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

private struct SystemCleanupConfirmationView: View {
    let plan: SystemCleanupPlan
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Review System Cleanup")
                    .font(.system(size: 18, weight: .bold))
                Text("Only the verified old cache and log files below will be moved to your Trash. Nothing is permanently deleted.")
                    .font(.system(size: 12))
                    .foregroundStyle(MoniPalette.foregroundTertiary)
            }

            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(SystemCleanupCategory.allCases, id: \.self) { category in
                        let categoryItems = readyItems.filter { $0.category == category }
                        if !categoryItems.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 8) {
                                    Text(MoniLocalization.string(category.titleKey))
                                        .font(.system(size: 12.5, weight: .bold))
                                    Spacer(minLength: 8)
                                    Text(MoniLocalization.format(
                                        "%@ files · %@",
                                        categoryItems.count.formatted(),
                                        maintenanceBytes(totalSize(of: categoryItems))
                                    ))
                                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                                    .foregroundStyle(MoniPalette.foregroundSecondary)
                                }

                                ForEach(categoryItems) { item in
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack(spacing: 8) {
                                            Text(item.name)
                                                .font(.system(size: 12, weight: .semibold))
                                                .lineLimit(1)
                                            Spacer(minLength: 8)
                                            Text(maintenanceBytes(item.sizeBytes))
                                                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                                .foregroundStyle(MoniPalette.orange)
                                        }
                                        Text(item.path)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(MoniPalette.foregroundTertiary)
                                            .lineLimit(2)
                                            .truncationMode(.middle)
                                            .textSelection(.enabled)
                                        Text(relativeDate(item.modifiedDate))
                                            .font(.system(size: 10))
                                            .foregroundStyle(MoniPalette.foregroundTertiary)
                                    }
                                    .padding(10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(MoniPalette.insetSecondary)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                }
                            }
                        }
                    }
                }
                .padding(1)
            }
            .frame(maxHeight: 360)

            if !plan.cleanupPlan.rejectedItems.isEmpty {
                Label(
                    MoniLocalization.format(
                        "%@ files are protected and will be kept.",
                        plan.cleanupPlan.rejectedItems.count.formatted()
                    ),
                    systemImage: "checkmark.shield"
                )
                .font(.system(size: 11.5))
                .foregroundStyle(MoniPalette.orange)
            }

            if let notice = plan.activePowerLogNotice {
                VStack(alignment: .leading, spacing: 5) {
                    Label(
                        MoniLocalization.format(
                            "Power telemetry database · %@ · active, kept",
                            maintenanceBytes(notice.sizeBytes)
                        ),
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(MoniPalette.orange)
                    Text(notice.path)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(MoniPalette.foregroundTertiary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }

            HStack {
                Text(MoniLocalization.format(
                    "%@ files · %@",
                    readyItems.count.formatted(),
                    maintenanceBytes(totalSize(of: readyItems))
                ))
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(MoniPalette.foregroundSecondary)
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Move to Trash", role: .destructive, action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .disabled(readyItems.isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 680)
    }

    private var readyItems: [SystemCleanupItem] {
        let paths = Set(plan.cleanupPlan.candidates.map(\.path))
        return plan.items.filter { paths.contains($0.path) }
    }

    private func totalSize(of items: [SystemCleanupItem]) -> UInt64 {
        items.reduce(0) { partial, item in
            let (sum, overflow) = partial.addingReportingOverflow(item.sizeBytes)
            return overflow ? UInt64.max : sum
        }
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = MoniLocalization.currentLanguage.locale
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

private func maintenanceBytes(_ value: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
}

private struct DiskVerificationReportView: View {
    let report: DiskVerificationReport
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: reportSymbol)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(reportColor)
                    .frame(width: 42, height: 42)
                    .background(MoniPalette.insetSecondary)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Startup Volume Verification")
                        .font(.system(size: 18, weight: .bold))
                    Text(MoniLocalization.string(reportTitle))
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(reportColor)
                }
            }

            ScrollView(.vertical, showsIndicators: true) {
                Text(report.result.detail.isEmpty
                    ? MoniLocalization.string("No diagnostic output was returned.")
                    : report.result.detail)
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .frame(height: 280)
            .background(MoniPalette.insetSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            if report.result.outcome == .attention {
                Label("Open Disk Utility and run First Aid before making further disk changes.", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(MoniPalette.orange)
            }

            HStack {
                Spacer()
                Button("Close", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620)
    }

    private var reportTitle: String {
        switch report.result.outcome {
        case .healthy: "Filesystem appears healthy"
        case .attention: "Filesystem needs attention"
        case .failed: "Verification did not complete successfully"
        case .unavailable: "Disk verification is unavailable"
        }
    }

    private var reportSymbol: String {
        switch report.result.outcome {
        case .healthy: "checkmark.circle.fill"
        case .attention: "exclamationmark.triangle.fill"
        case .failed, .unavailable: "xmark.circle.fill"
        }
    }

    private var reportColor: Color {
        switch report.result.outcome {
        case .healthy: MoniPalette.green
        case .attention: MoniPalette.orange
        case .failed, .unavailable: MoniPalette.red
        }
    }
}
