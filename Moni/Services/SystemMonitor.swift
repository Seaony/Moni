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
    private var timer: AnyCancellable?
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
    }

    func setSamplingInterval(_ interval: TimeInterval) {
        samplingInterval = interval
        start()
    }

    func refresh() {
        snapshot = sampler.sample()
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

