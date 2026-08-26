import Combine
import Foundation

@MainActor
final class SystemMonitor: ObservableObject {
    @Published private(set) var snapshot = SystemSnapshot()
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var memoryHistory: [Double] = []
    @Published private(set) var downloadHistory: [Double] = []
    @Published private(set) var uploadHistory: [Double] = []
    @Published private(set) var gpuHistory: [Double] = []
    @Published private(set) var diskReadHistory: [Double] = []
    @Published private(set) var diskWriteHistory: [Double] = []
    @Published private(set) var cpuTemperatureHistory: [Double] = []
    @Published private(set) var gpuTemperatureHistory: [Double] = []
    @Published private(set) var largestFolders: [StorageFolderUsage] = []
    @Published private(set) var isScanningStorage = false
    @Published private(set) var publicIPAddress: String?
    @Published private(set) var networkLatencyMilliseconds: Double?
    @Published private(set) var isLoadingNetworkExternalDetails = false

    private let sampler = SystemSampler()
    private let alertMonitor = AlertMonitor()
    private var timer: AnyCancellable?
    private var refreshTask: Task<Void, Never>?
    private var storageScanTask: Task<Void, Never>?
    private var networkExternalTask: Task<Void, Never>?
    private var didCompleteStorageScan = false
    private var lastNetworkExternalLoad: Date?
    private var samplingInterval: TimeInterval

    init(samplingInterval: TimeInterval = 1) {
        self.samplingInterval = samplingInterval
        refresh()
        start()
    }

    func start() {
        timer?.cancel()
        timer = Timer.publish(every: samplingInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refresh() }
    }

    func stop() {
        timer?.cancel()
        timer = nil
        refreshTask?.cancel()
        refreshTask = nil
        storageScanTask?.cancel()
        storageScanTask = nil
        networkExternalTask?.cancel()
        networkExternalTask = nil
    }

    func setSamplingInterval(_ interval: TimeInterval) {
        guard samplingInterval != interval else { return }
        samplingInterval = interval
        start()
    }

    func refresh(forceSlowMetrics: Bool = false) {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self, sampler] in
            let snapshot = await sampler.sample(forceSlowMetrics: forceSlowMetrics)
            guard !Task.isCancelled, let self else { return }
            apply(snapshot)
            refreshTask = nil
        }
    }

    func loadStorageFoldersIfNeeded() {
        guard !didCompleteStorageScan, storageScanTask == nil else { return }
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: PreferenceKey.storageFolderCache),
           let cached = try? JSONDecoder().decode([StorageFolderUsage].self, from: data) {
            largestFolders = cached
            let cacheDate = defaults.object(forKey: PreferenceKey.storageFolderCacheDate) as? Date
            if let cacheDate, Date().timeIntervalSince(cacheDate) < 6 * 60 * 60 {
                didCompleteStorageScan = true
                return
            }
        }
        isScanningStorage = true
        storageScanTask = Task { [weak self] in
            let folders = await Task.detached(priority: .utility) {
                Self.scanLargestFolders()
            }.value
            guard !Task.isCancelled, let self else { return }
            if !folders.isEmpty {
                largestFolders = folders
                if let data = try? JSONEncoder().encode(folders) {
                    defaults.set(data, forKey: PreferenceKey.storageFolderCache)
                    defaults.set(Date(), forKey: PreferenceKey.storageFolderCacheDate)
                }
            }
            isScanningStorage = false
            didCompleteStorageScan = true
            storageScanTask = nil
        }
    }

    func loadNetworkExternalDetailsIfNeeded(force: Bool = false) {
        if !force, let lastNetworkExternalLoad,
           Date().timeIntervalSince(lastNetworkExternalLoad) < 10 * 60 {
            return
        }
        guard networkExternalTask == nil else { return }
        isLoadingNetworkExternalDetails = true
        networkExternalTask = Task { [weak self] in
            var request = URLRequest(url: URL(string: "https://api.ipify.org")!)
            request.timeoutInterval = 5
            let startedAt = ContinuousClock.now
            let result: (String, Double)?
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let elapsed = startedAt.duration(to: .now)
                guard let http = response as? HTTPURLResponse,
                      http.statusCode == 200,
                      let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !value.isEmpty,
                      value.rangeOfCharacter(from: CharacterSet(charactersIn: "0123456789abcdefABCDEF.:").inverted) == nil
                else { throw URLError(.badServerResponse) }
                let milliseconds = Double(elapsed.components.seconds) * 1_000
                    + Double(elapsed.components.attoseconds) / 1e15
                result = (value, milliseconds)
            } catch {
                result = nil
            }
            guard !Task.isCancelled, let self else { return }
            publicIPAddress = result?.0
            networkLatencyMilliseconds = result?.1
            lastNetworkExternalLoad = result == nil ? nil : Date()
            isLoadingNetworkExternalDetails = false
            networkExternalTask = nil
        }
    }

    private func apply(_ snapshot: SystemSnapshot) {
        self.snapshot = snapshot
        alertMonitor.evaluate(snapshot)
        append(snapshot.cpu.total, to: &cpuHistory)
        append(snapshot.memory.usedPercent, to: &memoryHistory)
        append(snapshot.network.downloadBytesPerSecond, to: &downloadHistory)
        append(snapshot.network.uploadBytesPerSecond, to: &uploadHistory)
        append(snapshot.diskActivity.readBytesPerSecond, to: &diskReadHistory)
        append(snapshot.diskActivity.writeBytesPerSecond, to: &diskWriteHistory)
        if let gpu = snapshot.gpu.utilizationPercent {
            append(gpu, to: &gpuHistory)
        }
        if let temperature = snapshot.power.cpuTemperatureCelsius {
            append(temperature, to: &cpuTemperatureHistory)
        }
        if let temperature = snapshot.power.gpuTemperatureCelsius {
            append(temperature, to: &gpuTemperatureHistory)
        }
    }

    private func append(_ value: Double, to history: inout [Double]) {
        history.append(value)
        if history.count > 60 {
            history.removeFirst(history.count - 60)
        }
    }

    private nonisolated static func scanLargestFolders() -> [StorageFolderUsage] {
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        var paths = [homePath, "/Library", "/Applications"]
        let optionalPaths = [
            homePath + "/.orbstack",
            homePath + "/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw",
            homePath + "/Library/Group Containers/group.com.docker/Docker.raw",
        ]
        paths.append(contentsOf: optionalPaths.filter { FileManager.default.fileExists(atPath: $0) })
        let groupContainersPath = homePath + "/Library/Group Containers"
        if let names = try? FileManager.default.contentsOfDirectory(atPath: groupContainersPath) {
            paths.append(contentsOf: names
                .filter { $0.localizedCaseInsensitiveContains("orbstack") }
                .map { groupContainersPath + "/" + $0 })
        }

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/taskpolicy")
        process.arguments = ["-b", "/usr/bin/nice", "-n", "20", "/usr/bin/du", "-sk", "-x"] + paths
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard let text = String(data: data, encoding: .utf8) else { return [] }
            var folders: [StorageFolderUsage] = text.split(whereSeparator: \.isNewline).compactMap { line in
                let fields = line.split(separator: "\t", maxSplits: 1)
                guard fields.count == 2, let kilobytes = UInt64(fields[0]) else { return nil }
                return StorageFolderUsage(path: String(fields[1]), sizeBytes: kilobytes * 1_024)
            }
            if let systemSize = systemVolumeSize() {
                folders.append(StorageFolderUsage(path: "/System", sizeBytes: systemSize))
            }
            return folders
            .sorted { $0.sizeBytes > $1.sizeBytes }
            .prefix(5)
            .map { $0 }
        } catch {
            return []
        }
    }

    private nonisolated static func systemVolumeSize() -> UInt64? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["info", "-plist", "/"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard let propertyList = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                return nil
            }
            return (propertyList["CapacityInUse"] as? NSNumber)?.uint64Value
        } catch {
            return nil
        }
    }
}
