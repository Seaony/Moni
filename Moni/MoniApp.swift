//
//  MoniApp.swift
//  Moni
//
//  Created by seaony on 2026/8/26.
//

import SwiftUI

@main
struct MoniApp: App {
    @StateObject private var monitor = SystemMonitor()
    @StateObject private var aiUsage = AIUsageStore()

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(monitor)
                .environmentObject(aiUsage)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chart.bar.fill")
                Text("\(Int(monitor.snapshot.cpu.total.rounded()))%")
                    .monospacedDigit()
            }
        }
        .menuBarExtraStyle(.window)
    }
}
