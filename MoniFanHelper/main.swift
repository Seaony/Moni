@preconcurrency import Foundation
import Security
import Darwin

nonisolated final class FanHelperService: NSObject, MoniFanControlXPC, @unchecked Sendable {
    let queue = DispatchQueue(label: "com.seaony.Moni.FanHelper.control")
    private let controller = FanSMCController()
    private var lastContact = ProcessInfo.processInfo.systemUptime
    private var timer: DispatchSourceTimer?

    override init() {
        super.init()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, ProcessInfo.processInfo.systemUptime - self.lastContact > 10 else { return }
            try? self.controller.restoreAll()
        }
        self.timer = timer
        timer.resume()
    }

    func status(reply: @escaping (Data?, String?) -> Void) {
        queue.async {
            self.lastContact = ProcessInfo.processInfo.systemUptime
            do { reply(try JSONEncoder().encode(self.controller.status()), nil) }
            catch { reply(nil, error.localizedDescription) }
        }
    }

    func setSpeed(_ id: Int, rpm: Double, reply: @escaping (String?) -> Void) {
        perform(reply) { try self.controller.setSpeed(id, rpm: rpm) }
    }

    func setAutomatic(_ id: Int, reply: @escaping (String?) -> Void) {
        perform(reply) { try self.controller.setAutomatic(id) }
    }

    func restoreAll(reply: @escaping (String?) -> Void) {
        perform(reply) { try self.controller.restoreAll() }
    }

    func disconnected() {
        queue.async {
            self.lastContact = 0
            do {
                try self.controller.restoreAll()
                exit(0)
            } catch {
                // Keep the helper alive so its timer can retry restoring automatic control.
            }
        }
    }

    private func perform(_ reply: @escaping (String?) -> Void, action: @escaping () throws -> Void) {
        queue.async {
            self.lastContact = ProcessInfo.processInfo.systemUptime
            defer { self.lastContact = ProcessInfo.processInfo.systemUptime }
            do { try action(); reply(nil) }
            catch { reply(error.localizedDescription) }
        }
    }
}

nonisolated final class FanHelperDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let service = FanHelperService()
    private let connectionQueue = DispatchQueue(label: "com.seaony.Moni.FanHelper.connection")
    private var activeConnection: NSXPCConnection?
    private let requirement: String

    init?(applicationURL: URL) {
        var application: SecStaticCode?
        var requirement: SecRequirement?
        var requirementText: CFString?
        guard SecStaticCodeCreateWithPath(applicationURL as CFURL, [], &application) == errSecSuccess,
              let application,
              SecCodeCopyDesignatedRequirement(application, [], &requirement) == errSecSuccess,
              let requirement,
              SecRequirementCopyString(requirement, [], &requirementText) == errSecSuccess,
              let requirementText else { return nil }
        self.requirement = requirementText as String
        super.init()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connectionQueue.sync {
            guard activeConnection == nil else { return false }
            connection.setCodeSigningRequirement(requirement)
            connection.exportedInterface = NSXPCInterface(with: MoniFanControlXPC.self)
            connection.exportedObject = service
            let connectionID = ObjectIdentifier(connection)
            connection.invalidationHandler = { [weak self] in
                guard let self else { return }
                self.connectionQueue.async {
                    if self.activeConnection.map(ObjectIdentifier.init) == connectionID {
                        self.service.disconnected()
                        self.activeConnection = nil
                    }
                }
            }
            connection.interruptionHandler = { [weak connection] in connection?.invalidate() }
            activeConnection = connection
            connection.resume()
            return true
        }
    }
}

// The helper is embedded at Contents/Library/LaunchServices/MoniFanHelper.
var executablePath = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
guard proc_pidpath(getpid(), &executablePath, UInt32(executablePath.count)) > 0 else { exit(1) }
let applicationURL = URL(fileURLWithPath: String(cString: executablePath)).resolvingSymlinksInPath()
    .deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
guard let delegate = FanHelperDelegate(applicationURL: applicationURL) else { exit(1) }
let listener = NSXPCListener(machServiceName: FanControlConfiguration.serviceName)
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
