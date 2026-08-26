import Combine
import Foundation

@MainActor
final class SystemMonitor: ObservableObject {
    @Published private(set) var snapshot = SystemSnapshot()
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var memoryHistory: [Double] = []
    @Published private(set) var downloadHistory: [Double] = []
    @Published private(set) var uploadHistory: [Double] = []

    private let sampler = SystemSampler()
    private let alertMonitor = AlertMonitor()
    private var timer: AnyCancellable?
    private var refreshTask: Task<Void, Never>?
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

    private func apply(_ snapshot: SystemSnapshot) {
        self.snapshot = snapshot
        alertMonitor.evaluate(snapshot)
        append(snapshot.cpu.total, to: &cpuHistory)
        append(snapshot.memory.usedPercent, to: &memoryHistory)
        append(snapshot.network.downloadBytesPerSecond, to: &downloadHistory)
        append(snapshot.network.uploadBytesPerSecond, to: &uploadHistory)
    }

    private func append(_ value: Double, to history: inout [Double]) {
        history.append(value)
        if history.count > 60 {
            history.removeFirst(history.count - 60)
        }
    }
}
