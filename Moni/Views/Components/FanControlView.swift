import SwiftUI

struct FanControlView: View {
    @EnvironmentObject private var control: FanControlService

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(control.fans) { fan in
                FanControlRow(fan: fan)
            }
            if let error = control.error {
                Text(MoniLocalization.string(error))
                    .font(.system(size: 10))
                    .foregroundStyle(MoniPalette.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if control.fans.isEmpty {
                Text(MoniLocalization.string("Fan data unavailable"))
                    .font(.system(size: 10))
                    .foregroundStyle(MoniPalette.foregroundTertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 74)
        .background {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(MoniPalette.inset)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(MoniPalette.line, lineWidth: 1)
        }
    }
}

private struct FanControlRow: View {
    @EnvironmentObject private var control: FanControlService
    let fan: FanControlStatus
    @State private var pendingRPM: Double?
    @State private var isDragging = false
    @State private var isAutoHovered = false

    private var canAdjust: Bool {
        fan.isControllable && !control.isBusy
    }

    private var displayedRPM: Double {
        pendingRPM ?? (fan.isAutomatic ? fan.currentRPM : fan.targetRPM)
    }

    var body: some View {
        HStack(spacing: 6) {
            FanRotationIcon(rpm: fan.currentRPM)
                .foregroundStyle(MoniPalette.foregroundTertiary)
                .frame(width: 14)
                .accessibilityHidden(true)
            Text(MoniLocalization.string(fan.name == "Left fan" ? "Left" : fan.name == "Right fan" ? "Right" : "\(fan.id + 1)"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(MoniPalette.foregroundSecondary)
                .fixedSize()
                .frame(width: 36, alignment: .leading)
                .help(MoniLocalization.string(fan.name))
            Text(String(format: "%.0f", pendingRPM ?? fan.currentRPM))
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(MoniPalette.foreground)
                .frame(width: 36, alignment: .trailing)
                .help(String(format: "%.0f RPM", fan.currentRPM))

            if fan.isControllable && fan.maximumRPM > fan.minimumRPM {
                FanSpeedSlider(
                    value: min(fan.maximumRPM, max(fan.minimumRPM, displayedRPM)),
                    range: fan.minimumRPM...fan.maximumRPM,
                    isHighlighted: pendingRPM != nil || !fan.isAutomatic,
                    onChange: {
                        isDragging = true
                        pendingRPM = $0
                    },
                    onCommit: {
                        isDragging = false
                        guard let pendingRPM else { return }
                        control.setSpeed(fan.id, rpm: pendingRPM)
                    }
                )
                .disabled(!canAdjust)
                .help(String(format: "%.0f RPM", displayedRPM))
                .accessibilityLabel(MoniLocalization.string("Target fan speed"))
            } else {
                Text("—")
                    .frame(maxWidth: .infinity)
                    .help(MoniLocalization.string("Manual control unavailable"))
            }
            modeButton
        }
        .font(.system(size: 12))
        .frame(height: 28)
        .onChange(of: control.isBusy) { _, _ in
            clearConfirmedTarget()
        }
        .onChange(of: fan.targetRPM) { _, _ in
            clearConfirmedTarget()
        }
        .onChange(of: fan.isAutomatic) { _, _ in
            clearConfirmedTarget()
        }
        .onChange(of: control.error) { _, error in
            if error != nil && !isDragging { pendingRPM = nil }
        }
    }

    private func clearConfirmedTarget() {
        guard !isDragging, !control.isBusy, !fan.isAutomatic,
              let pendingRPM, abs(fan.targetRPM - pendingRPM) < 1 else { return }
        self.pendingRPM = nil
    }

    private var modeButton: some View {
        Button {
            pendingRPM = nil
            control.setAutomatic(fan.id)
        } label: {
            Text(MoniLocalization.string("Auto"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(fan.isAutomatic && pendingRPM == nil ? Color.white : (isAutoHovered && canAdjust ? MoniPalette.foreground : MoniPalette.foregroundTertiary))
                .frame(width: 40, height: 24)
                .background(
                    fan.isAutomatic && pendingRPM == nil
                        ? MoniPalette.blue.opacity(isAutoHovered && canAdjust ? 0.8 : 1)
                        : (isAutoHovered && canAdjust ? MoniPalette.controlHover : Color.clear)
                )
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(MoniPressButtonStyle(scale: 0.98))
        .disabled(!canAdjust)
        .onHover { isAutoHovered = $0 }
        .moniAnimation(MoniMotion.press, value: isAutoHovered)
        .help(MoniLocalization.string("Automatic"))
        .accessibilityLabel(MoniLocalization.string("Automatic"))
        .accessibilityAddTraits(fan.isAutomatic && pendingRPM == nil ? .isSelected : [])
    }
}

private struct FanRotationIcon: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var referenceDate = Date()
    @State private var referenceAngle = 0.0
    let rpm: Double

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || rpm <= 0)) { context in
            Image(systemName: "fan")
                .font(.system(size: 12))
                .rotationEffect(.degrees(reduceMotion ? 0 : angle(at: context.date, rpm: rpm)))
                .transaction { $0.animation = nil }
        }
        .onChange(of: rpm) { previousRPM, _ in
            let now = Date()
            referenceAngle = angle(at: now, rpm: previousRPM).truncatingRemainder(dividingBy: 360)
            referenceDate = now
        }
    }

    private func angle(at date: Date, rpm: Double) -> Double {
        // Slow the visual rotation while preserving its proportion to measured RPM.
        referenceAngle + date.timeIntervalSince(referenceDate) * max(0, rpm) * 0.075
    }
}

private struct FanSpeedSlider: View {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isThumbHovered = false
    let value: Double
    let range: ClosedRange<Double>
    let isHighlighted: Bool
    let onChange: (Double) -> Void
    let onCommit: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let travel = max(1, geometry.size.width - 16)
            let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            ZStack(alignment: .leading) {
                Capsule().fill(MoniPalette.track).frame(height: 10)
                Capsule()
                    .fill(isHighlighted ? MoniPalette.blue : MoniPalette.track)
                    .frame(width: 8 + travel * fraction, height: 10)
                Circle()
                    .fill(MoniPalette.foreground)
                    .frame(width: 16, height: 16)
                    .scaleEffect(isThumbHovered && isEnabled ? 1.15 : 1)
                    .animation(reduceMotion ? nil : MoniMotion.press, value: isThumbHovered && isEnabled)
                    .onHover { isThumbHovered = $0 }
                    .moniPointingHand()
                    .offset(x: travel * fraction)
            }
            .frame(height: 28)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { gesture in
                    guard isEnabled else { return }
                    let position = min(1, max(0, (gesture.location.x - 8) / travel))
                    onChange(range.lowerBound + position * (range.upperBound - range.lowerBound))
                }
                .onEnded { _ in if isEnabled { onCommit() } })
        }
        .frame(height: 28)
        .focusable(isEnabled)
        .focusEffectDisabled()
        .transaction { $0.animation = nil }
        .onMoveCommand { direction in
            if direction == .left { adjust(-100) }
            if direction == .right { adjust(100) }
        }
        .accessibilityElement()
        .accessibilityValue(String(format: "%.0f RPM", value))
        .accessibilityAdjustableAction { direction in
            adjust(direction == .increment ? 100 : -100)
        }
    }

    private func adjust(_ delta: Double) {
        guard isEnabled else { return }
        onChange(min(range.upperBound, max(range.lowerBound, value + delta)))
        onCommit()
    }
}
