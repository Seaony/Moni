import SwiftUI

struct DetailPanel<Content: View>: View {
    let title: String?
    @ViewBuilder let content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(MoniLocalization.string(title).uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(MoniPalette.foregroundSecondary)
                    .tracking(0.7)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(MoniPalette.card)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(MoniPalette.line, lineWidth: 1)
        }
    }
}
