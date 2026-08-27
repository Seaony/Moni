//
//  MoniApp.swift
//  Moni
//
//  Created by seaony on 2026/8/26.
//

import AppKit
import SwiftUI

@main
struct MoniApp: App {
    @StateObject private var monitor = SystemMonitor()
    @StateObject private var aiUsage = AIUsageStore()
    @StateObject private var updates = UpdateController()
    @AppStorage(PreferenceKey.compactMenuBar) private var compactMenuBar = false
    @AppStorage(PreferenceKey.menuBarMetric) private var menuBarMetric = MenuBarMetric.cpu.rawValue
    @AppStorage(PreferenceKey.menuBarItems) private var menuBarItems = "cpu,memory"
    @AppStorage(PreferenceKey.menuBarDisplayStyle) private var menuBarDisplayStyle = MenuBarDisplayStyle.valueOnly.rawValue

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(monitor)
                .environmentObject(aiUsage)
                .environmentObject(updates)
                .background(
                    MenuBarWindowPositioner { isVisible in
                        monitor.setPanelVisible(isVisible)
                    }
                )
        } label: {
            HStack(spacing: 7) {
                ForEach(Array(selectedMetrics.prefix(compactMenuBar ? 1 : 3))) { metric in
                    HStack(spacing: 3) {
                        if !compactMenuBar && displayStyle != .valueOnly {
                            MenuBarMiniGraph(values: history(metric))
                        }
                        if compactMenuBar || displayStyle != .graphOnly {
                            Text(menuBarValue(metric))
                                .monospacedDigit()
                                .moniNumericTransition(menuBarValue(metric))
                        }
                    }
                }
            }
            .moniAnimation(value: menuBarItems)
            .moniAnimation(value: menuBarDisplayStyle)
        }
        .menuBarExtraStyle(.window)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesCommand(updateController: updates)
            }
            CommandGroup(after: .newItem) {
                Button("Refresh") {
                    monitor.refresh(forceSlowMetrics: true)
                    monitor.loadNetworkExternalDetailsIfNeeded(force: true)
                    aiUsage.refreshCurrent(
                        includeQuotas: true,
                        allowKeychainPrompt: true
                    )
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
    }

    private var selectedMetric: MenuBarMetric {
        MenuBarMetric(rawValue: menuBarMetric) ?? .cpu
    }

    private var selectedMetrics: [MenuBarMetric] {
        let selection = Set(menuBarItems.split(separator: ",").map(String.init))
        let values = MenuBarMetric.allCases.filter { selection.contains($0.rawValue) }
        return values.isEmpty ? [selectedMetric] : values
    }

    private var displayStyle: MenuBarDisplayStyle {
        MenuBarDisplayStyle(rawValue: menuBarDisplayStyle) ?? .valueOnly
    }

    private func menuBarValue(_ metric: MenuBarMetric) -> String {
        switch metric {
        case .cpu:
            return "\(Int(monitor.snapshot.cpu.total.rounded()))%"
        case .memory:
            return "\(Int(monitor.snapshot.memory.usedPercent.rounded()))%"
        case .network:
            return "↓\(rate(monitor.snapshot.network.downloadBytesPerSecond))"
        case .disk:
            return "\(Int((monitor.snapshot.volumes.first { $0.mountPath == "/" }?.usedPercent ?? 0).rounded()))%"
        case .battery:
            return monitor.snapshot.power.batteryPercent.map { "\(Int($0.rounded()))%" } ?? "—"
        case .temperature:
            return monitor.snapshot.power.cpuTemperatureCelsius.map { "\(Int($0.rounded()))°" } ?? "—"
        }
    }

    private func history(_ metric: MenuBarMetric) -> [Double] {
        switch metric {
        case .cpu: monitor.cpuHistory
        case .memory: monitor.memoryHistory
        case .network: monitor.downloadHistory
        case .disk: monitor.diskReadHistory
        case .battery: monitor.batteryHistory
        case .temperature: monitor.cpuTemperatureHistory
        }
    }

    private func rate(_ value: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(max(0, value)), countStyle: .decimal) + "/s"
    }
}

private struct MenuBarMiniGraph: View {
    let values: [Double]

    var body: some View {
        GeometryReader { proxy in
            Path { path in
                let values = Array(values.suffix(18))
                guard values.count > 1,
                      let minimum = values.min(),
                      let maximum = values.max()
                else { return }
                let span = max(1, maximum - minimum)
                for (index, value) in values.enumerated() {
                    let x = proxy.size.width * CGFloat(index) / CGFloat(values.count - 1)
                    let y = proxy.size.height * CGFloat(1 - (value - minimum) / span)
                    if index == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
            }
            .stroke(.primary, style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 22, height: 12)
    }
}

private struct MenuBarWindowPositioner: NSViewRepresentable {
    let onVisibilityChange: (Bool) -> Void

    func makeNSView(context: Context) -> MenuBarWindowPositioningView {
        MenuBarWindowPositioningView(onVisibilityChange: onVisibilityChange)
    }

    func updateNSView(_ nsView: MenuBarWindowPositioningView, context: Context) {
        nsView.onVisibilityChange = onVisibilityChange
    }
}

private final class MenuBarWindowPositioningView: NSView {
    var onVisibilityChange: (Bool) -> Void

    private var observers: [NSObjectProtocol] = []

    init(onVisibilityChange: @escaping (Bool) -> Void) {
        self.onVisibilityChange = onVisibilityChange
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        removeObservers()
        guard let window else {
            onVisibilityChange(false)
            return
        }

        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                onVisibilityChange(true)
                centerWindowBelowMenuBarClick()
            }
        )
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.onVisibilityChange(false)
            }
        )

        // The window can exist before it is ever shown; only an on-screen window
        // counts, and `didBecomeKey` covers the moment it is actually opened.
        onVisibilityChange(window.isVisible)
        DispatchQueue.main.async { [weak self] in
            self?.centerWindowBelowMenuBarClick()
        }
    }

    deinit {
        removeObservers()
    }

    private func removeObservers() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    private func centerWindowBelowMenuBarClick() {
        guard let window, window.isVisible else { return }

        let clickLocation = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(clickLocation, $0.frame, false) }) else {
            return
        }
        guard clickLocation.y >= screen.frame.maxY - NSStatusBar.system.thickness - 8 else { return }

        let visibleFrame = screen.visibleFrame
        let centeredX = clickLocation.x - window.frame.width / 2
        let availableMaxX = max(visibleFrame.minX, visibleFrame.maxX - window.frame.width)
        let clampedX = min(max(centeredX, visibleFrame.minX), availableMaxX)
        window.setFrameOrigin(NSPoint(x: clampedX, y: window.frame.origin.y))
    }
}

private struct CheckForUpdatesCommand: View {
    @ObservedObject var updateController: UpdateController

    var body: some View {
        Button("Check for Updates…") {
            updateController.checkForUpdates()
        }
        .disabled(!updateController.canCheckForUpdates)
    }
}
