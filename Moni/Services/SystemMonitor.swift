import Combine
import Foundation

enum SystemHistoryMetric {
    case cpu
    case memory
    case loadAverage
    case download
    case upload
    case gpu
}

@MainActor
final class SystemMonitor: ObservableObject {
    @Published private(set) var snapshot = SystemSnapshot()
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
    private var recentHistory: [HistorySample] = []
    private var minuteHistory: [HistorySample] = []
    private var lastWidgetPersistence = Date.distantPast
    private var isPanelVisible = false

    private struct HistorySample {
        let date: Date
        let cpu: Double
        let memory: Double
        let loadAverage: Double
        let download: Double
        let upload: Double
        let gpu: Double?
        let diskRead: Double
        let diskWrite: Double
        let cpuTemperature: Double?
        let gpuTemperature: Double?
        let battery: Double?
    }

    init(samplingInterval: TimeInterval = 0.7) {
        self.samplingInterval = samplingInterval
        refresh()
        start()
    }

    func start() {
        timer?.cancel()
        timer = Timer.publish(every: activeInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refresh() }
    }

    /// The menu bar label only needs a coarse tick; the fast interval is for the
    /// open panel's charts.
    private var activeInterval: TimeInterval {
        isPanelVisible ? samplingInterval : max(samplingInterval, 2)
    }

    func setPanelVisible(_ isVisible: Bool) {
        guard isPanelVisible != isVisible else { return }
        isPanelVisible = isVisible
        start()
        // The forced refresh has to land after the sampler knows the panel is up,
        // otherwise it still runs the idle intervals for that first pass.
        Task { [sampler] in
            await sampler.setPanelVisible(isVisible)
            if isVisible {
                refresh(forceSlowMetrics: true)
            }
        }
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

    var cpuHistory: [Double] { recentHistory.map(\.cpu) }
    var recentHistoryDates: [Date] { recentHistory.map(\.date) }
    var memoryHistory: [Double] { recentHistory.map(\.memory) }
    var downloadHistory: [Double] { recentHistory.map(\.download) }
    var uploadHistory: [Double] { recentHistory.map(\.upload) }
    var gpuHistory: [Double] { recentHistory.compactMap(\.gpu) }
    var gpuHistoryDates: [Date] {
        recentHistory.compactMap { $0.gpu == nil ? nil : $0.date }
    }
    var diskReadHistory: [Double] { recentHistory.map(\.diskRead) }
    var diskWriteHistory: [Double] { recentHistory.map(\.diskWrite) }
    var cpuTemperatureHistory: [Double] { recentHistory.compactMap(\.cpuTemperature) }
    var cpuTemperatureHistoryDates: [Date] {
        recentHistory.compactMap { $0.cpuTemperature == nil ? nil : $0.date }
    }
    var gpuTemperatureHistory: [Double] { recentHistory.compactMap(\.gpuTemperature) }
    var batteryHistory: [Double] {
        let referenceDate = minuteHistory.last?.date ?? snapshot.date
        let cutoff = referenceDate.addingTimeInterval(-12 * 60 * 60)
        return minuteHistory.lazy
            .filter { $0.date >= cutoff }
            .compactMap(\.battery)
    }

    func history(_ metric: SystemHistoryMetric, duration: TimeInterval) -> [Double] {
        let source = duration <= 60 ? recentHistory : minuteHistory
        let referenceDate = source.last?.date ?? snapshot.date
        let cutoff = referenceDate.addingTimeInterval(-duration)
        return source.lazy
            .filter { $0.date >= cutoff }
            .compactMap { sample in
                switch metric {
                case .cpu: sample.cpu
                case .memory: sample.memory
                case .loadAverage: sample.loadAverage
                case .download: sample.download
                case .upload: sample.upload
                case .gpu: sample.gpu
                }
            }
    }

    func historyDates(_ metric: SystemHistoryMetric, duration: TimeInterval) -> [Date] {
        let source = duration <= 60 ? recentHistory : minuteHistory
        let referenceDate = source.last?.date ?? snapshot.date
        let cutoff = referenceDate.addingTimeInterval(-duration)
        return source.lazy
            .filter { $0.date >= cutoff }
            .compactMap { sample in
                if case .gpu = metric, sample.gpu == nil { return nil }
                return sample.date
            }
    }

    private func apply(_ snapshot: SystemSnapshot) {
        appendHistory(snapshot)
        self.snapshot = snapshot
        alertMonitor.evaluate(snapshot)
        persistWidgetSnapshotIfNeeded(snapshot)
    }

    private func persistWidgetSnapshotIfNeeded(_ snapshot: SystemSnapshot) {
        guard snapshot.date.timeIntervalSince(lastWidgetPersistence) >= 15 else { return }
        lastWidgetPersistence = snapshot.date
        let widgetSnapshot = WidgetSystemSnapshot(
            snapshot: snapshot,
            histories: .init(
                cpu: cpuHistory,
                memory: memoryHistory,
                download: downloadHistory,
                upload: uploadHistory,
                gpu: gpuHistory,
                diskRead: diskReadHistory,
                diskWrite: diskWriteHistory,
                battery: batteryHistory
            ),
            publicIPAddress: publicIPAddress,
            networkLatencyMilliseconds: networkLatencyMilliseconds,
            storageFolders: largestFolders
        )
        Task {
            await WidgetSnapshotWriter.shared.persistSystem(widgetSnapshot)
        }
    }

    private func appendHistory(_ snapshot: SystemSnapshot) {
        let sample = HistorySample(
            date: snapshot.date,
            cpu: snapshot.cpu.total,
            memory: snapshot.memory.usedPercent,
            loadAverage: snapshot.host.loadAverages.first ?? 0,
            download: snapshot.network.downloadBytesPerSecond,
            upload: snapshot.network.uploadBytesPerSecond,
            gpu: snapshot.gpu.utilizationPercent,
            diskRead: snapshot.diskActivity.readBytesPerSecond,
            diskWrite: snapshot.diskActivity.writeBytesPerSecond,
            cpuTemperature: snapshot.power.cpuTemperatureCelsius,
            gpuTemperature: snapshot.power.gpuTemperatureCelsius,
            battery: snapshot.power.batteryPercent
        )
        recentHistory.append(sample)
        let recentCutoff = snapshot.date.addingTimeInterval(-60)
        recentHistory.removeAll { $0.date < recentCutoff }

        let minute = floor(snapshot.date.timeIntervalSince1970 / 60)
        if let last = minuteHistory.last,
           floor(last.date.timeIntervalSince1970 / 60) == minute {
            minuteHistory[minuteHistory.count - 1] = sample
        } else {
            minuteHistory.append(sample)
            let dayCutoff = snapshot.date.addingTimeInterval(-86_400)
            minuteHistory.removeAll { $0.date < dayCutoff }
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
