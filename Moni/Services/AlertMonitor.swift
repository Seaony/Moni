import Foundation
import UserNotifications

@MainActor
final class AlertMonitor {
    private var activeAlerts: Set<String> = []
    private var lastNotification: [String: Date] = [:]

    func evaluate(_ snapshot: SystemSnapshot) {
        let defaults = UserDefaults.standard
        evaluate(
            id: "cpu",
            title: "CPU usage is high",
            value: snapshot.cpu.total,
            enabled: defaults.bool(forKey: PreferenceKey.cpuAlertEnabled),
            threshold: threshold(PreferenceKey.cpuAlertThreshold, fallback: 85)
        )
        evaluate(
            id: "memory",
            title: "Memory usage is high",
            value: snapshot.memory.usedPercent,
            enabled: defaults.bool(forKey: PreferenceKey.memoryAlertEnabled),
            threshold: threshold(PreferenceKey.memoryAlertThreshold, fallback: 90)
        )
        evaluate(
            id: "disk",
            title: "System disk is nearly full",
            value: snapshot.volumes.first { $0.mountPath == "/" }?.usedPercent ?? 0,
            enabled: defaults.bool(forKey: PreferenceKey.diskAlertEnabled),
            threshold: threshold(PreferenceKey.diskAlertThreshold, fallback: 90)
        )
    }

    private func threshold(_ key: String, fallback: Double) -> Double {
        let value = UserDefaults.standard.double(forKey: key)
        return value == 0 ? fallback : value
    }

    private func evaluate(id: String, title: String, value: Double, enabled: Bool, threshold: Double) {
        guard enabled else {
            activeAlerts.remove(id)
            lastNotification.removeValue(forKey: id)
            return
        }

        guard value >= threshold else {
            activeAlerts.remove(id)
            lastNotification.removeValue(forKey: id)
            return
        }

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
        content.body = "Current usage is \(Int(value.rounded()))%; the configured threshold is \(Int(threshold.rounded()))%."
        if defaults.bool(forKey: PreferenceKey.alertSounds) {
            content.sound = .default
        }
        let request = UNNotificationRequest(identifier: "moni.\(id).\(Date().timeIntervalSince1970)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
