import Combine
import Foundation

@MainActor
final class SystemMonitor: ObservableObject {
    @Published private(set) var snapshot = SystemSnapshot()

    private let sampler = SystemSampler()
    private let alertMonitor = AlertMonitor()
    private var timer: AnyCancellable?
    private var refreshTask: Task<Void, Never>?
    private var samplingInterval: TimeInterval
    private var recentHistory: [HistorySample] = []
    private var minuteHistory: [HistorySample] = []
    private var isPanelVisible = false

    private struct HistorySample {
        let date: Date
        let cpu: Double
        let memory: Double
        let download: Double
        let upload: Double
        let gpu: Double?
        let diskRead: Double
        let cpuTemperature: Double?
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
    var cpuTemperatureHistory: [Double] { recentHistory.compactMap(\.cpuTemperature) }
    var cpuTemperatureHistoryDates: [Date] {
        recentHistory.compactMap { $0.cpuTemperature == nil ? nil : $0.date }
    }
    var batteryHistory: [Double] {
        let referenceDate = minuteHistory.last?.date ?? snapshot.date
        let cutoff = referenceDate.addingTimeInterval(-12 * 60 * 60)
        return minuteHistory.lazy
            .filter { $0.date >= cutoff }
            .compactMap(\.battery)
    }

    private func apply(_ snapshot: SystemSnapshot) {
        appendHistory(snapshot)
        self.snapshot = snapshot
        alertMonitor.evaluate(snapshot)
    }

    private func appendHistory(_ snapshot: SystemSnapshot) {
        let sample = HistorySample(
            date: snapshot.date,
            cpu: snapshot.cpu.total,
            memory: snapshot.memory.usedPercent,
            download: snapshot.network.downloadBytesPerSecond,
            upload: snapshot.network.uploadBytesPerSecond,
            gpu: snapshot.gpu.utilizationPercent,
            diskRead: snapshot.diskActivity.readBytesPerSecond,
            cpuTemperature: snapshot.power.cpuTemperatureCelsius,
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
}
