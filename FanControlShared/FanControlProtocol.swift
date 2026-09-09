import Foundation

nonisolated enum FanControlConfiguration {
    static let serviceName = "com.seaony.Moni.FanHelper"
}

@objc nonisolated protocol MoniFanControlXPC {
    func status(reply: @escaping (Data?, String?) -> Void)
    func setSpeed(_ id: Int, rpm: Double, reply: @escaping (String?) -> Void)
    func setAutomatic(_ id: Int, reply: @escaping (String?) -> Void)
    func restoreAll(reply: @escaping (String?) -> Void)
}

nonisolated struct FanControlStatus: Codable, Sendable, Identifiable {
    let id: Int
    let name: String
    let currentRPM: Double
    let minimumRPM: Double
    let maximumRPM: Double
    let targetRPM: Double
    let isAutomatic: Bool
    let isControllable: Bool
}
