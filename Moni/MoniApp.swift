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
    @StateObject private var updates = UpdateController()
    @StateObject private var cacheCleanupScanner = CacheCleanupScanner()
    @AppStorage(PreferenceKey.appLanguage) private var appLanguage = AppLanguage.english.rawValue

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(monitor)
                .environmentObject(updates)
                .environmentObject(cacheCleanupScanner)
                .background(
                    MenuBarWindowPositioner { isVisible in
                        monitor.setPanelVisible(isVisible)
                    }
                )
        } label: {
            MenuBarStatusLabel(monitor: monitor)
        }
        .menuBarExtraStyle(.window)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesCommand(updateController: updates)
            }
            CommandGroup(after: .newItem) {
                Button(MoniLocalization.string("Refresh", language: selectedLanguage)) {
                    monitor.refresh(forceSlowMetrics: true)
                    monitor.loadNetworkExternalDetailsIfNeeded(force: true)
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
    }

    private var selectedLanguage: AppLanguage {
        AppLanguage(rawValue: appLanguage) ?? .english
    }
}

private struct MenuBarStatusLabel: View {
    @ObservedObject var monitor: SystemMonitor
    @AppStorage(PreferenceKey.compactMenuBar) private var compactMenuBar = false
    @AppStorage(PreferenceKey.menuBarMetric) private var menuBarMetric = MenuBarMetric.cpu.rawValue
    @AppStorage(PreferenceKey.menuBarItems) private var menuBarItems = "cpu,memory"
    @AppStorage(PreferenceKey.menuBarDisplayStyle) private var menuBarDisplayStyle = MenuBarDisplayStyle.valueOnly.rawValue
    @AppStorage(PreferenceKey.appLanguage) private var appLanguage = AppLanguage.english.rawValue

    var body: some View {
        menuBarContent
            .environment(\.locale, selectedLanguage.locale)
            .monospacedDigit()
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel(accessibilityLabel)
            .moniAnimation(value: menuBarItems)
            .moniAnimation(value: menuBarDisplayStyle)
    }

    private var selectedMetric: MenuBarMetric {
        MenuBarMetric(rawValue: menuBarMetric) ?? .cpu
    }

    private var selectedLanguage: AppLanguage {
        AppLanguage(rawValue: appLanguage) ?? .english
    }

    private var selectedMetrics: [MenuBarMetric] {
        let selection = Set(menuBarItems.split(separator: ",").map(String.init))
        let values = MenuBarMetric.allCases.filter { selection.contains($0.rawValue) }
        return values.isEmpty ? [selectedMetric] : values
    }

    private var visibleMetrics: [MenuBarMetric] {
        compactMenuBar ? Array(selectedMetrics.prefix(1)) : selectedMetrics
    }

    private var displayStyle: MenuBarDisplayStyle {
        MenuBarDisplayStyle(rawValue: menuBarDisplayStyle) ?? .valueOnly
    }

    @ViewBuilder
    private var menuBarContent: some View {
        switch displayStyle {
        case .valueOnly:
            Text(valueLabel)
        case .graphOnly:
            Image(nsImage: MenuBarGraphRenderer.image(items: renderItems, includesValues: false))
                .renderingMode(.template)
        case .graphAndValue:
            Image(nsImage: MenuBarGraphRenderer.image(items: renderItems, includesValues: true))
                .renderingMode(.template)
        }
    }

    private var valueLabel: String {
        visibleMetrics
            .map { "\(menuBarTag($0)) \(menuBarValue($0))" }
            .joined(separator: "  ")
    }

    private var renderItems: [MenuBarGraphRenderer.Item] {
        visibleMetrics.map { metric in
            MenuBarGraphRenderer.Item(
                values: history(metric),
                value: menuBarValue(metric)
            )
        }
    }

    private var accessibilityLabel: String {
        visibleMetrics
            .map { "\(MoniLocalization.string($0.title, language: selectedLanguage)) \(menuBarValue($0))" }
            .joined(separator: ", ")
    }

    private func menuBarTag(_ metric: MenuBarMetric) -> String {
        switch metric {
        case .temperature: "TMP"
        default: String(metric.title.prefix(3)).uppercased()
        }
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

struct MenuBarMiniGraph: View {
    let values: [Double]
    var color: Color = .primary

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
            .stroke(color, style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 22, height: 12)
    }
}

private enum MenuBarGraphRenderer {
    struct Item {
        let values: [Double]
        let value: String
    }

    private static let graphSize = NSSize(width: 22, height: 12)
    private static let itemSpacing: CGFloat = 8
    private static let graphTextSpacing: CGFloat = 4
    private static let valueAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
        .foregroundColor: NSColor.black,
    ]

    static func image(items: [Item], includesValues: Bool) -> NSImage {
        let itemWidths = items.map { itemWidth($0, includesValues: includesValues) }
        let contentWidth = itemWidths.reduce(0, +)
            + itemSpacing * CGFloat(max(0, items.count - 1))
        let size = NSSize(width: max(1, ceil(contentWidth)), height: 14)
        let image = NSImage(size: size, flipped: false) { bounds in
            var x = bounds.minX
            for (index, item) in items.enumerated() {
                drawGraph(
                    item.values,
                    in: NSRect(
                        x: x,
                        y: bounds.midY - graphSize.height / 2,
                        width: graphSize.width,
                        height: graphSize.height
                    )
                )
                x += graphSize.width

                if includesValues {
                    x += graphTextSpacing
                    x += draw(item.value, at: x, in: bounds, attributes: valueAttributes)
                }

                if index < items.count - 1 { x += itemSpacing }
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func itemWidth(_ item: Item, includesValues: Bool) -> CGFloat {
        guard includesValues else { return graphSize.width }
        return graphSize.width
            + graphTextSpacing
            + textSize(item.value, attributes: valueAttributes).width
    }

    private static func draw(
        _ value: String,
        at x: CGFloat,
        in bounds: NSRect,
        attributes: [NSAttributedString.Key: Any]
    ) -> CGFloat {
        let size = textSize(value, attributes: attributes)
        (value as NSString).draw(
            at: NSPoint(x: x, y: floor(bounds.midY - size.height / 2)),
            withAttributes: attributes
        )
        return size.width
    }

    private static func textSize(
        _ value: String,
        attributes: [NSAttributedString.Key: Any]
    ) -> NSSize {
        (value as NSString).size(withAttributes: attributes)
    }

    private static func drawGraph(_ source: [Double], in bounds: NSRect) {
        let values = Array(source.suffix(18))
        guard !values.isEmpty else { return }
        let minimum = values.min() ?? 0
        let maximum = values.max() ?? minimum
        let horizontalInset: CGFloat = 1
        let verticalInset: CGFloat = 1
        let drawingWidth = max(0, bounds.width - horizontalInset * 2)
        let drawingHeight = max(0, bounds.height - verticalInset * 2)
        let path = NSBezierPath()
        path.lineWidth = 1.2
        path.lineCapStyle = .round
        path.lineJoinStyle = .round

        for (index, value) in values.enumerated() {
            let fraction = maximum > minimum ? (value - minimum) / (maximum - minimum) : 0.5
            let x = bounds.minX + horizontalInset
                + drawingWidth * CGFloat(index) / CGFloat(max(1, values.count - 1))
            let y = bounds.minY + verticalInset + drawingHeight * CGFloat(fraction)
            let point = NSPoint(x: x, y: y)
            if index == 0 {
                path.move(to: point)
            } else {
                path.line(to: point)
            }
        }

        if values.count == 1 {
            path.line(to: NSPoint(x: bounds.maxX - horizontalInset, y: path.currentPoint.y))
        }
        NSColor.black.setStroke()
        path.stroke()
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

@MainActor
private final class MenuBarWindowAnchor {
    static let shared = MenuBarWindowAnchor()

    var centerX: CGFloat?
    var topY: CGFloat?
    var visibleFrame: NSRect?
}

private final class MenuBarWindowPositioningView: NSView {
    var onVisibilityChange: (Bool) -> Void

    private var observers: [NSObjectProtocol] = []
    private let anchor = MenuBarWindowAnchor.shared
    private var isApplyingOrigin = false

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
                updateAnchorFromMenuBarClick()
                captureAnchorIfNeeded()
                restoreAnchoredOrigin()
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
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.restoreAnchoredOrigin()
            }
        )
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSWindow.didMoveNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.restoreAnchoredOrigin()
            }
        )

        // The window can exist before it is ever shown; only an on-screen window
        // counts, and `didBecomeKey` covers the moment it is actually opened.
        onVisibilityChange(window.isVisible)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            updateAnchorFromMenuBarClick()
            captureAnchorIfNeeded()
            restoreAnchoredOrigin()
        }
    }

    deinit {
        removeObservers()
    }

    private func removeObservers() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    private func updateAnchorFromMenuBarClick() {
        guard let window, window.isVisible else { return }

        let clickLocation = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(clickLocation, $0.frame, false) }) else {
            return
        }
        guard clickLocation.y >= screen.frame.maxY - NSStatusBar.system.thickness - 8 else { return }

        anchor.centerX = clickLocation.x
        anchor.topY = window.frame.maxY
        anchor.visibleFrame = screen.visibleFrame
    }

    private func captureAnchorIfNeeded() {
        guard let window, window.isVisible else { return }
        if anchor.centerX == nil {
            anchor.centerX = window.frame.midX
        }
        if anchor.topY == nil {
            anchor.topY = window.frame.maxY
        }
        if anchor.visibleFrame == nil {
            anchor.visibleFrame = window.screen?.visibleFrame
        }
    }

    private func restoreAnchoredOrigin() {
        guard !isApplyingOrigin,
              let window,
              window.isVisible,
              let centerX = anchor.centerX,
              let topY = anchor.topY,
              let visibleFrame = anchor.visibleFrame
        else {
            return
        }

        let maximumX = max(visibleFrame.minX, visibleFrame.maxX - window.frame.width)
        let originX = min(
            max(centerX - window.frame.width / 2, visibleFrame.minX),
            maximumX
        )
        let maximumY = max(visibleFrame.minY, visibleFrame.maxY - window.frame.height)
        let originY = min(
            max(topY - window.frame.height, visibleFrame.minY),
            maximumY
        )
        guard abs(window.frame.minX - originX) > 0.5
                || abs(window.frame.minY - originY) > 0.5
        else {
            return
        }

        isApplyingOrigin = true
        window.setFrameOrigin(NSPoint(x: originX, y: originY))
        isApplyingOrigin = false
    }
}

private struct CheckForUpdatesCommand: View {
    @ObservedObject var updateController: UpdateController

    var body: some View {
        Button(MoniLocalization.string("Check for Updates…")) {
            updateController.checkForUpdates()
        }
        .disabled(!updateController.canCheckForUpdates)
    }
}
