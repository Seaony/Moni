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

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(monitor)
                .environmentObject(aiUsage)
                .environmentObject(updates)
                .background(MenuBarWindowPositioner())
        } label: {
            HStack(spacing: 4) {
                if !compactMenuBar {
                    Image(systemName: selectedMetric.symbol)
                        .transition(MoniMotion.itemTransition)
                }
                Text(menuBarValue)
                    .monospacedDigit()
                    .moniNumericTransition(menuBarValue)
            }
            .moniAnimation(value: compactMenuBar)
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
                        allowClaudeKeychainPrompt: true
                    )
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
    }

    private var selectedMetric: MenuBarMetric {
        MenuBarMetric(rawValue: menuBarMetric) ?? .cpu
    }

    private var menuBarValue: String {
        switch selectedMetric {
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
        }
    }

    private func rate(_ value: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(max(0, value)), countStyle: .decimal) + "/s"
    }
}

private struct MenuBarWindowPositioner: NSViewRepresentable {
    func makeNSView(context: Context) -> MenuBarWindowPositioningView {
        MenuBarWindowPositioningView()
    }

    func updateNSView(_ nsView: MenuBarWindowPositioningView, context: Context) {}
}

private final class MenuBarWindowPositioningView: NSView {
    private var keyWindowObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if let keyWindowObserver {
            NotificationCenter.default.removeObserver(keyWindowObserver)
        }
        guard let window else { return }

        keyWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.centerWindowBelowMenuBarClick()
        }

        DispatchQueue.main.async { [weak self] in
            self?.centerWindowBelowMenuBarClick()
        }
    }

    deinit {
        if let keyWindowObserver {
            NotificationCenter.default.removeObserver(keyWindowObserver)
        }
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
