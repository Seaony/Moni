import SwiftUI

struct MetricCard<Content: View>: View {
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
        .background(Color.primary.opacity(0.055))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
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
