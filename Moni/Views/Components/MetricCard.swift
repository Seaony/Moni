import SwiftUI

struct MetricCard<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    let title: String
    let symbol: String
    let color: Color
    var trailing: String?
    @ViewBuilder let content: Content

    init(
        title: String,
        symbol: String,
        color: Color,
        trailing: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.symbol = symbol
        self.color = color
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 14, height: 14)
                    .frame(width: 16, height: 16)
                Text(title)
                    .fontWeight(.bold)
                Spacer(minLength: 4)
                if let trailing {
                    Text(trailing)
                        .foregroundStyle(.secondary)
                        .moniNumericTransition(trailing)
                }
            }
            .font(.system(size: 14))
            .foregroundStyle(color)

            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 205, maxHeight: .infinity, alignment: .topLeading)
        .background(isHovered ? MoniPalette.cardHover : MoniPalette.card)
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(MoniPalette.line, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : MoniMotion.press, value: isHovered)
    }
}

struct MetricRow: View {
    let label: String
    let value: String
    var color: Color = .secondary

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value)
                .fontWeight(.semibold)
                .monospacedDigit()
                .moniNumericTransition(value)
        }
        .font(.system(size: 12))
    }
}
