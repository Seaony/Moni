import SwiftUI

enum WidgetTheme {
    static let foreground = Color.primary
    static let secondary = Color.secondary
    static let tertiary = Color.secondary.opacity(0.72)
    static let track = Color.primary.opacity(0.12)
    static let inset = Color.primary.opacity(0.06)
    static let pink = Color(red: 1, green: 0.216, blue: 0.373)
    static let blue = Color(red: 0.039, green: 0.518, blue: 1)
    static let cyan = Color(red: 0.196, green: 0.678, blue: 0.902)
    static let orange = Color(red: 1, green: 0.624, blue: 0.039)
    static let purple = Color(red: 0.749, green: 0.353, blue: 0.941)
    static let indigo = Color(red: 0.369, green: 0.361, blue: 0.902)
    static let red = Color(red: 1, green: 0.271, blue: 0.227)
    static let green = Color(red: 0.188, green: 0.82, blue: 0.345)
    static let yellow = Color(red: 1, green: 0.839, blue: 0.039)
}

struct WidgetHeader: View {
    let title: String
    let symbol: String
    let color: Color
    var trailing: String?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
            Text(MoniLocalization.string(title))
                .font(.system(size: 12.5, weight: .bold))
            Spacer(minLength: 4)
            if let trailing {
                Text(MoniLocalization.string(trailing))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(WidgetTheme.tertiary)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(color)
    }
}

struct WidgetBars: View {
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            let maximum = max(1, values.max() ?? 1)
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color)
                        .frame(height: max(3, geometry.size.height * value / maximum))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

struct WidgetRing<Content: View>: View {
    let progress: Double
    let color: Color
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            Circle()
                .stroke(WidgetTheme.track, lineWidth: 10)
            Circle()
                .trim(from: 0, to: min(1, max(0, progress)))
                .stroke(color, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
            content
        }
        .accessibilityElement(children: .contain)
    }
}

struct WidgetLineChart: View {
    let values: [Double]
    let color: Color
    var showsFill = true

    var body: some View {
        GeometryReader { geometry in
            let points = normalizedPoints(values, in: geometry.size)
            if points.count > 1 {
                ZStack {
                    if showsFill {
                        Path { path in
                            path.move(to: CGPoint(x: points[0].x, y: geometry.size.height))
                            points.forEach { path.addLine(to: $0) }
                            path.addLine(to: CGPoint(x: points.last?.x ?? 0, y: geometry.size.height))
                            path.closeSubpath()
                        }
                        .fill(LinearGradient(colors: [color.opacity(0.32), color.opacity(0.01)], startPoint: .top, endPoint: .bottom))
                    }
                    Path { path in
                        path.move(to: points[0])
                        points.dropFirst().forEach { path.addLine(to: $0) }
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func normalizedPoints(_ values: [Double], in size: CGSize) -> [CGPoint] {
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
