import Foundation

enum MaintenanceCategory: String, CaseIterable, Sendable {
    case system
    case finder
    case storage
    case privacy

    var titleKey: String {
        switch self {
        case .system: "System"
        case .finder: "Finder"
        case .storage: "Storage"
        case .privacy: "Privacy"
        }
    }
}

enum MaintenanceAuthorization: Sendable {
    case user
    case administrator
}

enum MaintenanceExecutionPolicy: Sendable {
    case immediate
    case requiresInactiveApplications
}

struct MaintenanceTaskDefinition: Identifiable, Sendable {
    let id: String
    let titleKey: String
    let descriptionKey: String
    let symbol: String
    let category: MaintenanceCategory
    let authorization: MaintenanceAuthorization
    let executionPolicy: MaintenanceExecutionPolicy
}

enum MaintenanceService {
    static let tasks: [MaintenanceTaskDefinition] = [
        task(
            "system_maintenance", "DNS & Spotlight Check",
            "Refresh DNS cache and verify Spotlight status.", "checkmark.shield",
            .system, authorization: .administrator
        ),
        task(
            "cache_refresh", "Finder Cache Refresh",
            "Refresh Quick Look thumbnails and icon services caches.", "photo.stack",
            .finder
        ),
        task(
            "saved_state_cleanup", "App State Cleanup",
            "Remove saved application states that have not changed for more than 30 days.",
            "clock.arrow.circlepath", .storage
        ),
        task(
            "fix_broken_configs", "Broken Config Repair",
            "Find malformed third-party preference files so they can be safely reset.",
            "wrench.and.screwdriver", .system
        ),
        task(
            "network_optimization", "Network Cache Refresh",
            "Flush the DNS cache and restart mDNSResponder.", "network",
            .system, authorization: .administrator
        ),
        task(
            "sqlite_vacuum", "Database Optimization",
            "Compact supported Mail, Safari, and Messages databases while their apps are closed.",
            "cylinder.split.1x2", .storage, policy: .requiresInactiveApplications
        ),
        task(
            "launch_services_rebuild", "LaunchServices Repair",
            "Rebuild file associations and the Open With menu.", "doc.badge.gearshape",
            .system
        ),
        task(
            "prevent_network_dsstore", "Prevent Finder .DS_Store",
            "Stop Finder from writing .DS_Store files on network and USB volumes.",
            "externaldrive.badge.xmark", .finder
        ),
        task(
            "legacy_overrides_audit", "Legacy Overrides",
            "Remove hidden App Nap and disk-image verification overrides left by old tweak tools.",
            "slider.horizontal.3", .system
        ),
        task(
            "network_stack_optimize", "Network Stack Refresh",
            "Flush routing and ARP caches to resolve network issues.", "point.3.connected.trianglepath.dotted",
            .system, authorization: .administrator
        ),
        task(
            "disk_permissions_repair", "Permission Repair",
            "Reset permissions for the current user home directory.", "person.badge.key",
            .system, authorization: .administrator
        ),
        task(
            "spotlight_index_optimize", "Spotlight Optimization",
            "Inspect Spotlight and rebuild the startup volume index only when needed.",
            "magnifyingglass.circle", .system, authorization: .administrator
        ),
        task(
            "spotlight_orphan_rules_cleanup", "Spotlight Orphan Rules",
            "Remove Spotlight search rules that reference applications no longer installed.",
            "magnifyingglass", .system
        ),
        task(
            "periodic_maintenance", "Periodic Maintenance",
            "Run macOS daily, weekly, and monthly maintenance scripts when stale.",
            "calendar.badge.clock", .system, authorization: .administrator
        ),
        task(
            "shared_file_list_repair", "Shared File Lists",
            "Repair malformed Finder favorites and recent-item lists.", "list.bullet.rectangle",
            .finder
        ),
        task(
            "disk_verify", "Disk Health",
            "Verify the startup filesystem without modifying it.", "internaldrive",
            .storage
        ),
        task(
            "login_items_audit", "Login Items",
            "Find login items whose referenced application or executable no longer exists.",
            "rectangle.stack.badge.person.crop", .system
        ),
        task(
            "quarantine_cleanup", "Quarantine Database Cleanup",
            "Clear Gatekeeper download history without changing file quarantine flags.",
            "lock.doc", .privacy
        ),
        task(
            "launch_agents_cleanup", "Launch Agents Cleanup",
            "Find user LaunchAgents whose referenced executable no longer exists.",
            "bolt.badge.xmark", .system
        ),
        task(
            "notification_cleanup", "Notifications",
            "Remove old delivered notifications to reduce notification database size.",
            "bell.badge", .privacy
        ),
        task(
            "coreduet_cleanup", "Usage Data",
            "Remove old local usage-tracking records from supported system databases.",
            "chart.bar.xaxis", .privacy
        )
    ]

    private static func task(
        _ id: String,
        _ titleKey: String,
        _ descriptionKey: String,
        _ symbol: String,
        _ category: MaintenanceCategory,
        authorization: MaintenanceAuthorization = .user,
        policy: MaintenanceExecutionPolicy = .immediate
    ) -> MaintenanceTaskDefinition {
        MaintenanceTaskDefinition(
            id: id,
            titleKey: titleKey,
            descriptionKey: descriptionKey,
            symbol: symbol,
            category: category,
            authorization: authorization,
            executionPolicy: policy
        )
    }
}
