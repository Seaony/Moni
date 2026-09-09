import Foundation

nonisolated final class FanSMCController {
    private let reader = SMCSensorReader()
    private var ownedFans: Set<Int> = []
    private var originalTestMode: Double?

    private enum ControlError: LocalizedError {
        case invalidFan, invalidSpeed, unavailable
        case manualNotAccepted, automaticNotAccepted, targetNotAccepted, restorationFailed
        var errorDescription: String? {
            switch self {
            case .invalidFan: return "Fan is unavailable."
            case .invalidSpeed: return "Speed is outside the hardware limits."
            case .unavailable: return "Fan control is unavailable on this Mac."
            case .manualNotAccepted: return "Manual fan control could not be confirmed."
            case .automaticNotAccepted: return "System automatic fan control could not be confirmed."
            case .targetNotAccepted: return "The requested fan speed could not be confirmed."
            case .restorationFailed: return "Fan control failed and automatic control could not be restored."
            }
        }
    }

    func status() -> [FanControlStatus] {
        guard let count = finiteValue("FNum"), count >= 0, count <= 8, count.rounded() == count else { return [] }
        return (0..<Int(count)).compactMap { id in
            guard let current = finiteValue(key(id, "Ac")) else { return nil }
            let minimum = finiteValue(key(id, "Mn"))
            let maximum = finiteValue(key(id, "Mx"))
            let target = finiteValue(key(id, "Tg"))
            let manual = manualMode(id)
            let limitsValid = minimum != nil && maximum != nil && minimum! >= 0 && maximum! > minimum!
            return FanControlStatus(
                id: id, name: count == 2 ? (id == 0 ? "Left fan" : "Right fan") : "Fan \(id + 1)", currentRPM: current,
                minimumRPM: minimum ?? 0, maximumRPM: maximum ?? 0, targetRPM: target ?? current,
                isAutomatic: manual != true,
                isControllable: manual != nil && target != nil && limitsValid
            )
        }
    }

    func setSpeed(_ id: Int, rpm: Double) throws {
        guard let fan = status().first(where: { $0.id == id }) else { throw ControlError.invalidFan }
        guard fan.isControllable else { throw ControlError.unavailable }
        guard rpm.isFinite, rpm >= fan.minimumRPM, rpm <= fan.maximumRPM else { throw ControlError.invalidSpeed }
        // Do not take over a fan already controlled by another process.
        guard fan.isAutomatic || ownedFans.contains(id) else { throw ControlError.unavailable }
        ownedFans.insert(id)
        do {
            var manualAccepted = !fan.isAutomatic
            if !manualAccepted {
                do {
                    try setManual(id, enabled: true)
                    manualAccepted = waitForChange { self.manualMode(id) == true }
                } catch {
                    guard finiteValue("Ftst") != nil else { throw error }
                }
            }
            if !manualAccepted, let testMode = finiteValue("Ftst") {
                if originalTestMode == nil {
                    originalTestMode = testMode
                }
                let deadline = ProcessInfo.processInfo.systemUptime + 20
                var testModeAccepted = false
                repeat {
                    do {
                        try reader.writeValue(1, for: "Ftst")
                        testModeAccepted = true
                        break
                    } catch {
                        Thread.sleep(forTimeInterval: 0.2)
                    }
                } while ProcessInfo.processInfo.systemUptime < deadline - 3
                guard testModeAccepted else { throw ControlError.manualNotAccepted }
                // Allow thermalmonitord to release control before requesting manual mode.
                Thread.sleep(forTimeInterval: 3)
                while ProcessInfo.processInfo.systemUptime < deadline {
                    do { try setManual(id, enabled: true) } catch { }
                    if waitForChange(timeout: 0.2, { self.manualMode(id) == true }) {
                        manualAccepted = true
                        break
                    }
                }
            }
            guard manualAccepted else { throw ControlError.manualNotAccepted }
            try reader.writeValue(rpm, for: key(id, "Tg"))
            guard waitForChange({
                guard let target = self.finiteValue(self.key(id, "Tg")) else { return false }
                return self.manualMode(id) == true && abs(target - rpm) < 1
            }) else { throw ControlError.targetNotAccepted }
        } catch {
            do { try setAutomatic(id) }
            catch { throw ControlError.restorationFailed }
            throw error
        }
    }

    func setAutomatic(_ id: Int) throws {
        guard ownedFans.contains(id) else {
            try restoreTestModeIfNeeded()
            return
        }
        try setManual(id, enabled: false)
        guard waitForChange({ self.manualMode(id) == false }) else { throw ControlError.automaticNotAccepted }
        #if arch(arm64)
        try reader.writeValue(0, for: key(id, "Tg"))
        #endif
        ownedFans.remove(id)
        try restoreTestModeIfNeeded()
    }

    func restoreAll() throws {
        var firstError: Error?
        for id in ownedFans.sorted() {
            do { try setAutomatic(id) } catch { if firstError == nil { firstError = error } }
        }
        do { try restoreTestModeIfNeeded() } catch { if firstError == nil { firstError = error } }
        if let firstError { throw firstError }
    }

    private func restoreTestModeIfNeeded() throws {
        guard ownedFans.isEmpty, let originalTestMode else { return }
        try reader.writeValue(originalTestMode, for: "Ftst")
        guard waitForChange({ self.finiteValue("Ftst") == originalTestMode }) else { throw ControlError.restorationFailed }
        self.originalTestMode = nil
    }

    private func waitForChange(timeout: TimeInterval = 2, _ isConfirmed: () -> Bool) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        repeat {
            if isConfirmed() { return true }
            Thread.sleep(forTimeInterval: 0.05)
        } while ProcessInfo.processInfo.systemUptime < deadline
        return isConfirmed()
    }

    private func key(_ id: Int, _ suffix: String) -> String {
        "F\(String(id, radix: 16).uppercased())\(suffix)"
    }

    private func finiteValue(_ key: String) -> Double? {
        guard let value = reader.value(for: key), value.isFinite else { return nil }
        return value
    }

    private func modeKey(_ id: Int) -> String? {
        for suffix in ["md", "Md"] {
            let candidate = key(id, suffix)
            if finiteValue(candidate) != nil { return candidate }
        }
        return nil
    }

    private func manualMode(_ id: Int) -> Bool? {
        if let mode = modeKey(id), let value = finiteValue(mode) {
            switch value {
            case 1: return true
            case 0, 3: return false
            default: return nil
            }
        }
        guard let mask = finiteValue("FS! "), mask >= 0, mask <= 65535, mask.rounded() == mask else { return nil }
        return Int(mask) & (1 << id) != 0
    }

    private func setManual(_ id: Int, enabled: Bool) throws {
        if let mode = modeKey(id) {
            try reader.writeValue(enabled ? 1 : 0, for: mode)
        } else {
            guard let value = finiteValue("FS! "), value >= 0, value <= 65535, value.rounded() == value else { throw ControlError.unavailable }
            let bit = 1 << id
            let mask = enabled ? Int(value) | bit : Int(value) & ~bit
            try reader.writeValue(Double(mask), for: "FS! ")
        }
    }
}
