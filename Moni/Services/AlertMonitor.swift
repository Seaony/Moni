import Foundation
import UserNotifications

@MainActor
final class AlertMonitor {
    /// A single 0.7s sample over the line is noise — a build, a page load — and
    /// alerting on it turns every burst into a banner. The limit has to hold for
    /// this long before it counts.
    private static let sustainInterval: TimeInterval = 30

    private var activeAlerts: Set<String> = []
    private var lastNotification: [String: Date] = [:]
    private var exceededSince: [String: Date] = [:]

    func evaluate(_ snapshot: SystemSnapshot) {
        let defaults = UserDefaults.standard
        let alertsEnabled = defaults.bool(forKey: PreferenceKey.notificationAlerts)
        evaluate(
            id: "cpu",
            title: MoniLocalization.string("CPU usage is high"),
            value: snapshot.cpu.total,
            enabled: alertsEnabled,
            threshold: threshold(PreferenceKey.cpuAlertThreshold, fallback: 85)
        )
        evaluate(
            id: "memory",
            title: MoniLocalization.string("Memory usage is high"),
            value: snapshot.memory.usedPercent,
            enabled: alertsEnabled,
            threshold: threshold(PreferenceKey.memoryAlertThreshold, fallback: 90)
        )
        if let temperature = snapshot.power.cpuTemperatureCelsius {
            evaluate(
                id: "temperature",
                title: MoniLocalization.string("CPU temperature is high"),
                value: temperature,
                enabled: alertsEnabled,
                threshold: threshold(PreferenceKey.temperatureAlertThreshold, fallback: 80),
                unit: "°C"
            )
        } else {
            reset("temperature")
        }
        evaluate(
            id: "disk",
            title: MoniLocalization.string("System disk is nearly full"),
            value: snapshot.volumes.first { $0.mountPath == "/" }?.usedPercent ?? 0,
            enabled: alertsEnabled,
            threshold: threshold(PreferenceKey.diskAlertThreshold, fallback: 90)
        )
    }

    /// `bool(forKey:)` reads an unset key as `false`, which would silence the
    /// sound the settings screen shows as enabled by default.
    private func flag(_ key: String, fallback: Bool) -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: key) != nil else { return fallback }
        return defaults.bool(forKey: key)
    }

    private func threshold(_ key: String, fallback: Double) -> Double {
        let value = UserDefaults.standard.double(forKey: key)
        return value == 0 ? fallback : value
    }

    private func evaluate(
        id: String,
        title: String,
        value: Double,
        enabled: Bool,
        threshold: Double,
        unit: String = "%"
    ) {
        guard enabled else {
            reset(id)
            return
        }

        guard value >= threshold else {
            reset(id)
            return
        }

        let now = Date()
        let since = exceededSince[id] ?? now
        exceededSince[id] = since
        guard now.timeIntervalSince(since) >= Self.sustainInterval else { return }

        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: PreferenceKey.notificationAlerts) else {
            activeAlerts.remove(id)
            lastNotification.removeValue(forKey: id)
            return
        }
        let shouldRepeat = defaults.bool(forKey: PreferenceKey.repeatAlerts)
        let canRepeat = shouldRepeat && Date().timeIntervalSince(lastNotification[id] ?? .distantPast) >= 300
        guard !activeAlerts.contains(id) || canRepeat else { return }

        activeAlerts.insert(id)
        lastNotification[id] = Date()

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = MoniLocalization.format(
            "Now at %@%@; the configured threshold is %@%@.",
            String(Int(value.rounded())),
            unit,
            String(Int(threshold.rounded())),
            unit
        )
        if flag(PreferenceKey.alertSounds, fallback: true) {
            content.sound = .default
        }
        let request = UNNotificationRequest(identifier: "moni.\(id).\(Date().timeIntervalSince1970)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func reset(_ id: String) {
        activeAlerts.remove(id)
        lastNotification.removeValue(forKey: id)
        exceededSince.removeValue(forKey: id)
    }
}
