import SwiftUI

struct Sparkline: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            let points = normalizedPoints(in: geometry.size)

            ZStack {
                if points.count > 1 {
                    Path { path in
                        path.move(to: CGPoint(x: points[0].x, y: geometry.size.height))
                        points.forEach { path.addLine(to: $0) }
                        path.addLine(to: CGPoint(x: points.last?.x ?? 0, y: geometry.size.height))
                        path.closeSubpath()
                    }
                    .fill(
                        LinearGradient(
                            colors: [color.opacity(0.35), color.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                    Path { path in
                        path.move(to: points[0])
                        points.dropFirst().forEach { path.addLine(to: $0) }
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                }
            }
            .id(values)
            .transition(.opacity)
            .animation(reduceMotion ? nil : MoniMotion.data, value: values)
        }
        .accessibilityHidden(true)
    }

    private func normalizedPoints(in size: CGSize) -> [CGPoint] {
        guard values.count > 1 else { return [] }
        let minimum = values.min() ?? 0
        let maximum = values.max() ?? 1
        let range = max(1, maximum - minimum)

        return values.enumerated().map { index, value in
            CGPoint(
                x: CGFloat(index) / CGFloat(values.count - 1) * size.width,
                y: size.height - CGFloat((value - minimum) / range) * max(1, size.height - 4) - 2
            )
        }
    }
}
