import AppKit
import Combine
import ServiceManagement
import OSLog

@MainActor
final class FanControlService: ObservableObject {
    @Published private(set) var fans: [FanControlStatus] = []
    @Published private(set) var isBusy = false
    @Published private(set) var error: String?
    @Published private(set) var requiresApproval = false
    @Published private(set) var isEnabled = false

    private let daemon = SMAppService.daemon(plistName: "com.seaony.Moni.FanHelper.plist")
    private let reader = FanControlReader()
    private var connection: NSXPCConnection?
    private var connectionVerified = false
    private var subscriptions: Set<AnyCancellable> = []
    private var refreshTask: Task<Void, Never>?
    private var isSleeping = false
    private var pendingSpeeds: [Int: Double] = [:]
    private var controlRevision = 0

    init() {
        Timer.publish(every: 2, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &subscriptions)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)
            .sink { [weak self] _ in
                self?.isSleeping = true
                self?.connection?.invalidate()
                self?.connection = nil
            }
            .store(in: &subscriptions)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in
                self?.isSleeping = false
                self?.refresh()
            }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in self?.connection?.invalidate() }
            .store(in: &subscriptions)
        refresh()
    }

    private func enable() {
        do {
            if daemon.status == .notRegistered || daemon.status == .notFound {
                try daemon.register()
            }
            updateAuthorization()
            if requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            error = nil
            refresh()
        } catch {
            pendingSpeeds.removeAll()
            self.error = error.localizedDescription
            updateAuthorization()
        }
    }

    func setAutomatic(_ id: Int) {
        pendingSpeeds.removeValue(forKey: id)
        perform { proxy, reply in proxy.setAutomatic(id, reply: reply) }
    }

    func setSpeed(_ id: Int, rpm: Double) {
        guard !isBusy, !isSleeping,
              let fan = fans.first(where: { $0.id == id }), fan.isControllable,
              rpm.isFinite, rpm >= fan.minimumRPM, rpm <= fan.maximumRPM else { return }
        updateAuthorization()
        guard isEnabled else {
            pendingSpeeds[id] = rpm
            enable()
            return
        }
        pendingSpeeds.removeValue(forKey: id)
        perform { proxy, reply in proxy.setSpeed(id, rpm: rpm, reply: reply) }
    }

    private func updateAuthorization() {
        isEnabled = daemon.status == .enabled
        requiresApproval = daemon.status == .requiresApproval
        if !isEnabled {
            connection?.invalidate()
            connection = nil
        }
    }

    private func refresh() {
        guard refreshTask == nil, !isSleeping, !isBusy else { return }
        updateAuthorization()
        refreshTask = Task {
            defer { refreshTask = nil }
            var revision = controlRevision
            let sampledFans = await reader.read()
            guard !isBusy, revision == controlRevision else { return }
            if isEnabled {
                do {
                    let helperFans = try await readHelper()
                    guard !isBusy, revision == controlRevision else { return }
                    fans = helperFans
                    if !pendingSpeeds.isEmpty {
                        let requestedSpeeds = pendingSpeeds
                        pendingSpeeds.removeAll()
                        controlRevision += 1
                        revision = controlRevision
                        isBusy = true
                        defer { isBusy = false }
                        for (id, rpm) in requestedSpeeds.sorted(by: { $0.key < $1.key }) {
                            try await command { proxy, reply in proxy.setSpeed(id, rpm: rpm, reply: reply) }
                        }
                        fans = try await readHelper()
                    }
                }
                catch {
                    guard revision == controlRevision else { return }
                    if !connectionVerified { fans = sampledFans }
                    self.error = error.localizedDescription
                    Logger(subsystem: "com.seaony.Moni", category: "FanControl").error("Status failed: \(error.localizedDescription, privacy: .public)")
                }
            } else {
                fans = sampledFans
            }
        }
    }

    private func perform(_ operation: @escaping (MoniFanControlXPC, @escaping (String?) -> Void) -> Void) {
        guard isEnabled, !isBusy, !isSleeping else { return }
        controlRevision += 1
        isBusy = true
        error = nil
        Task {
            do {
                try await command(operation)
                fans = try await readHelper()
            } catch {
                if let currentFans = try? await readHelper() { fans = currentFans }
                self.error = error.localizedDescription
            }
            isBusy = false
        }
    }

    private func helperConnection() -> NSXPCConnection {
        if let connection { return connection }
        let newConnection = NSXPCConnection(machServiceName: "com.seaony.Moni.FanHelper", options: .privileged)
        newConnection.remoteObjectInterface = NSXPCInterface(with: MoniFanControlXPC.self)
        newConnection.invalidationHandler = { [weak self, weak newConnection] in
            Task { @MainActor in
                guard let self, self.connection === newConnection else { return }
                self.connection = nil
            }
        }
        newConnection.interruptionHandler = { [weak newConnection] in newConnection?.invalidate() }
        newConnection.resume()
        connectionVerified = false
        connection = newConnection
        return newConnection
    }

    private func readHelper() async throws -> [FanControlStatus] {
        let data: Data = try await request { proxy, finish in
            proxy.status { data, message in
                if let message { finish(.failure(FanControlError(message: message))) }
                else if let data { finish(.success(data)) }
                else { finish(.failure(FanControlError(message: "Fan control returned no data."))) }
            }
        }
        let statuses = try JSONDecoder().decode([FanControlStatus].self, from: data)
        if !connectionVerified {
            error = nil
            connectionVerified = true
            Logger(subsystem: "com.seaony.Moni", category: "FanControl").notice("Connected: \(statuses.count) fans")
        }
        return statuses
    }

    private func command(_ operation: @escaping (MoniFanControlXPC, @escaping (String?) -> Void) -> Void) async throws {
        let _: Data = try await request { proxy, finish in
            operation(proxy) { message in
                if let message { finish(.failure(FanControlError(message: message))) }
                else { finish(.success(Data())) }
            }
        }
    }

    private func request(_ operation: (MoniFanControlXPC, @escaping (Result<Data, Error>) -> Void) -> Void) async throws -> Data {
        let currentConnection = helperConnection()
        return try await withCheckedThrowingContinuation { continuation in
            let reply = FanControlReply(continuation)
            let finish: (Result<Data, Error>) -> Void = { result in
                Task { @MainActor in reply.finish(result) }
            }
            guard let proxy = currentConnection.remoteObjectProxyWithErrorHandler({ finish(.failure($0)) }) as? MoniFanControlXPC else {
                finish(.failure(FanControlError(message: "Fan control service is unavailable.")))
                return
            }
            operation(proxy, finish)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(30))
                if reply.finish(.failure(FanControlError(message: "Fan control service timed out."))) {
                    currentConnection.invalidate()
                }
            }
        }
    }
}

@MainActor
private final class FanControlReply {
    private var continuation: CheckedContinuation<Data, Error>?

    init(_ continuation: CheckedContinuation<Data, Error>) { self.continuation = continuation }

    @discardableResult
    func finish(_ result: Result<Data, Error>) -> Bool {
        guard let continuation else { return false }
        self.continuation = nil
        continuation.resume(with: result)
        return true
    }
}

private struct FanControlError: LocalizedError {
    let message: String
    var errorDescription: String? { MoniLocalization.string(message) }
}

private actor FanControlReader {
    private let smc = SMCSensorReader()

    func read() -> [FanControlStatus] {
        guard let count = smc.value(for: "FNum"), count.isFinite, count >= 0, count <= 8 else { return [] }
        return (0..<Int(count)).compactMap { id in
            guard let current = smc.value(for: "F\(id)Ac"), current.isFinite, current >= 0 else { return nil }
            let minimumValue = smc.value(for: "F\(id)Mn")
            let maximumValue = smc.value(for: "F\(id)Mx")
            let minimum = minimumValue.flatMap { $0.isFinite ? $0 : nil } ?? 0
            let maximum = maximumValue.flatMap { $0.isFinite ? $0 : nil } ?? 0
            let target = smc.value(for: "F\(id)Tg").flatMap { $0.isFinite ? $0 : nil }
            let mode = smc.value(for: "F\(id)md") ?? smc.value(for: "F\(id)Md")
            let forced = smc.value(for: "FS! ")
            let automatic = mode.map { $0 == 0 || $0 == 3 }
                ?? forced.map { $0.isFinite && $0 >= 0 && $0 <= 65_535 && Int($0) & (1 << id) == 0 }
                ?? true
            return FanControlStatus(
                id: id,
                name: Int(count) == 2 ? (id == 0 ? "Left fan" : "Right fan") : "Fan \(id + 1)",
                currentRPM: current,
                minimumRPM: minimum,
                maximumRPM: maximum,
                targetRPM: target ?? current,
                isAutomatic: automatic,
                isControllable: minimumValue?.isFinite == true && maximumValue?.isFinite == true && target != nil && minimum >= 0 && maximum > minimum && (mode == 0 || mode == 1 || mode == 3 || forced != nil)
            )
        }
    }
}
