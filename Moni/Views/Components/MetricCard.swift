import SwiftUI

struct MetricCard<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(PreferenceKey.summaryGridDensity)
    private var gridDensityValue = SummaryGridDensity.comfortable.rawValue
    @State private var isHovered = false

    let title: String
    let symbol: String
    let color: Color
    var trailing: String?
    var trailingSymbol: String?
    var trailingHelp: String?
    var allowsContentOverflow: Bool
    @ViewBuilder let content: Content

    init(
        title: String,
        symbol: String,
        color: Color,
        trailing: String? = nil,
        trailingSymbol: String? = nil,
        trailingHelp: String? = nil,
        allowsContentOverflow: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.symbol = symbol
        self.color = color
        self.trailing = trailing
        self.trailingSymbol = trailingSymbol
        self.trailingHelp = trailingHelp
        self.allowsContentOverflow = allowsContentOverflow
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        let card = VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 14, height: 14)
                    .frame(width: 16, height: 16)
                Text(MoniLocalization.string(title))
                    .fontWeight(.bold)
                Spacer(minLength: 4)
                if let trailing {
                    if let trailingHelp {
                        Text(MoniLocalization.string(trailing))
                            .foregroundStyle(MoniPalette.foregroundSecondary)
                            .moniNumericTransition(trailing)
                            .help(MoniLocalization.string(trailingHelp))
                    } else {
                        Text(MoniLocalization.string(trailing))
                            .foregroundStyle(MoniPalette.foregroundSecondary)
                            .moniNumericTransition(trailing)
                    }
                }
                if let trailingSymbol {
                    Image(systemName: trailingSymbol)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(MoniPalette.foregroundTertiary)
                }
            }
            .font(.system(size: 14))
            .foregroundStyle(color)

            content
        }
        .padding(16)
        // Without a floor the card grows past the row it was given and paints over
        // the next one; the floor has to track the density or it overflows the
        // shorter compact rows instead.
        .frame(
            maxWidth: .infinity,
            minHeight: rowHeight,
            maxHeight: .infinity,
            alignment: .topLeading
        )
        .background {
            shape.fill(isHovered ? MoniPalette.cardHover : MoniPalette.card)
        }
        .overlay {
            shape
                .strokeBorder(MoniPalette.line, lineWidth: 1)
        }
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : MoniMotion.press, value: isHovered)

        if allowsContentOverflow {
            card
        } else {
            card.clipShape(shape)
        }
    }

    private var rowHeight: CGFloat {
        (SummaryGridDensity(rawValue: gridDensityValue) ?? .comfortable).rowHeight
    }
}

struct MetricRow: View {
    let label: String
    let value: String
    var color: Color = .secondary
    var helpText: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(MoniLocalization.string(label))
                .foregroundStyle(MoniPalette.foregroundSecondary)
            Spacer(minLength: 4)
            if let helpText {
                Text(MoniLocalization.string(value))
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .moniNumericTransition(value)
                    .help(MoniLocalization.string(helpText))
            } else {
                Text(MoniLocalization.string(value))
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .moniNumericTransition(value)
            }
        }
        .font(.system(size: 12))
    }
}
