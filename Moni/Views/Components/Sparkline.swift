import SwiftUI

struct InteractiveSparklineSeries {
    let name: String
    let values: [Double]
    let color: Color
    var showsFill = false
    let formatValue: (Double) -> String
}

struct InteractiveSparkline: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoveredIndex: Int?

    let series: [InteractiveSparklineSeries]
    let dates: [Date]
    var lineWidth = 2.2

    var body: some View {
        GeometryReader { geometry in
            let sampleCount = series.map(\.values.count).max() ?? 0

            ZStack(alignment: .topLeading) {
                ForEach(Array(series.enumerated()), id: \.offset) { _, item in
                    seriesPath(item, in: geometry.size)
                }

                if let hoveredIndex, sampleCount > 1 {
                    let x = xPosition(
                        for: hoveredIndex,
                        sampleCount: sampleCount,
                        width: geometry.size.width
                    )

                    Rectangle()
                        .fill(MoniPalette.foregroundTertiary.opacity(0.7))
                        .frame(width: 1, height: geometry.size.height)
                        .position(x: x, y: geometry.size.height / 2)
                        .allowsHitTesting(false)

                    ForEach(Array(series.enumerated()), id: \.offset) { _, item in
                        if let point = point(
                            for: hoveredIndex,
                            values: item.values,
                            in: geometry.size
                        ) {
                            Circle()
                                .fill(item.color)
                                .frame(width: 7, height: 7)
                                .overlay(Circle().stroke(MoniPalette.card, lineWidth: 2))
                                .position(point)
                                .allowsHitTesting(false)
                        }
                    }

                    tooltip(index: hoveredIndex)
                        .fixedSize()
                        .position(
                            x: tooltipX(hoveredX: x, width: geometry.size.width),
                            y: tooltipHeight / 2
                        )
                        .allowsHitTesting(false)
                        .transition(
                            reduceMotion
                                ? .identity
                                : .opacity.combined(with: .scale(scale: 0.96))
                        )
                        .zIndex(2)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    guard sampleCount > 0 else { return }
                    let fraction = min(max(location.x / max(1, geometry.size.width), 0), 1)
                    let index = Int((fraction * CGFloat(max(0, sampleCount - 1))).rounded())
                    guard index != hoveredIndex else { return }
                    hoveredIndex = index
                case .ended:
                    hoveredIndex = nil
                }
            }
        }
        .onDisappear {
            hoveredIndex = nil
        }
        .accessibilityLabel("Interactive history chart")
    }

    @ViewBuilder
    private func seriesPath(_ item: InteractiveSparklineSeries, in size: CGSize) -> some View {
        let points = normalizedPoints(values: item.values, in: size)
        if points.count > 1 {
            if item.showsFill {
                Path { path in
                    path.move(to: CGPoint(x: points[0].x, y: size.height))
                    points.forEach { path.addLine(to: $0) }
                    path.addLine(to: CGPoint(x: points.last?.x ?? 0, y: size.height))
                    path.closeSubpath()
                }
                .fill(
                    LinearGradient(
                        colors: [item.color.opacity(0.35), item.color.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }

            Path { path in
                path.move(to: points[0])
                points.dropFirst().forEach { path.addLine(to: $0) }
            }
            .stroke(
                item.color,
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
            )
        }
    }

    private func tooltip(index: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if dates.indices.contains(index) {
                Text(dates[index].formatted(date: .omitted, time: .standard))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(MoniPalette.foregroundSecondary)
                    .monospacedDigit()
            }

            ForEach(Array(series.enumerated()), id: \.offset) { _, item in
                if item.values.indices.contains(index) {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(item.color)
                            .frame(width: 6, height: 6)
                        Text(item.name)
                            .foregroundStyle(MoniPalette.foregroundSecondary)
                        Spacer(minLength: 8)
                        Text(item.formatValue(item.values[index]))
                            .fontWeight(.bold)
                            .foregroundStyle(MoniPalette.foreground)
                            .monospacedDigit()
                    }
                }
            }
        }
        .font(.system(size: 10.5))
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(minWidth: 116)
        .background(MoniPalette.controlHover)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(MoniPalette.panelLine, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.28), radius: 8, y: 3)
    }

    private var tooltipHeight: CGFloat {
        series.count > 1 ? 54 : 42
    }

    private func tooltipX(hoveredX: CGFloat, width: CGFloat) -> CGFloat {
        let halfWidth: CGFloat = 66
        // Sit left of the cursor, flipping to the right when that would run past
        // the chart's leading edge, then clamp so the card never clips it.
        let preferred = hoveredX - halfWidth - 12
        let candidate = preferred - halfWidth < 0 ? hoveredX + halfWidth + 12 : preferred
        return min(max(candidate, halfWidth), max(halfWidth, width - halfWidth))
    }

    private func xPosition(for index: Int, sampleCount: Int, width: CGFloat) -> CGFloat {
        CGFloat(index) / CGFloat(max(1, sampleCount - 1)) * width
    }

    private func point(for index: Int, values: [Double], in size: CGSize) -> CGPoint? {
        guard values.indices.contains(index), values.count > 1 else { return nil }
        let minimum = values.min() ?? 0
        let maximum = values.max() ?? 1
        let range = max(1, maximum - minimum)
        return CGPoint(
            x: xPosition(for: index, sampleCount: values.count, width: size.width),
            y: size.height - CGFloat((values[index] - minimum) / range) * max(1, size.height - 4) - 2
        )
    }

    private func normalizedPoints(values: [Double], in size: CGSize) -> [CGPoint] {
        guard values.count > 1 else { return [] }
        let minimum = values.min() ?? 0
        let maximum = values.max() ?? 1
        let range = max(1, maximum - minimum)

        return values.enumerated().map { index, value in
            CGPoint(
                x: xPosition(for: index, sampleCount: values.count, width: size.width),
                y: size.height - CGFloat((value - minimum) / range) * max(1, size.height - 4) - 2
            )
        }
    }
}
