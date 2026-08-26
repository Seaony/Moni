//
//  MoniApp.swift
//  Moni
//
//  Created by seaony on 2026/8/26.
//

import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let showsDockIcon = UserDefaults.standard.bool(forKey: PreferenceKey.showDockIcon)
        NSApp.setActivationPolicy(showsDockIcon ? .regular : .accessory)
    }
}

@main
struct MoniApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var monitor = SystemMonitor()
    @StateObject private var aiUsage = AIUsageStore()
    @AppStorage(PreferenceKey.compactMenuBar) private var compactMenuBar = false
    @AppStorage(PreferenceKey.menuBarMetric) private var menuBarMetric = MenuBarMetric.cpu.rawValue
    @AppStorage(PreferenceKey.showDockIcon) private var showDockIcon = false

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(monitor)
                .environmentObject(aiUsage)
        } label: {
            HStack(spacing: 4) {
                if !compactMenuBar {
                    Image(systemName: selectedMetric.symbol)
                }
                Text(menuBarValue)
                    .monospacedDigit()
            }
        }
        .menuBarExtraStyle(.window)

        Window("Moni", id: "dashboard") {
            ContentView()
                .environmentObject(monitor)
                .environmentObject(aiUsage)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(showDockIcon ? .presented : .suppressed)
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
