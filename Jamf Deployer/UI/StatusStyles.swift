import SwiftUI

/// A status or warning line whose symbol carries the color while the text
/// keeps the readable label color, as JTKit's `StatusIndicator` does.
/// System orange, yellow and green text fall well below the 4.5:1 contrast
/// small text needs on a light background.
struct TintedIconLabelStyle: LabelStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        Label {
            configuration.title
        } icon: {
            configuration.icon
                .foregroundStyle(tint)
        }
    }
}

extension LabelStyle where Self == TintedIconLabelStyle {
    /// Colors only the symbol: `Label(…).labelStyle(.tintedIcon(.orange))`.
    static func tintedIcon(_ tint: Color) -> TintedIconLabelStyle {
        TintedIconLabelStyle(tint: tint)
    }
}

/// One side of a field change: "− before" or "+ after", in the readable
/// label color on a light red or green wash, so the text keeps its contrast
/// and the sign, not only the color, says which side it is.
struct DiffLine: View {
    enum Side {
        case before
        case after
    }

    let side: Side
    let text: String

    init(_ side: Side, _ text: String) {
        self.side = side
        self.text = text
    }

    var body: some View {
        Text("\(side == .before ? "−" : "+") \(text)")
            .font(.caption.monospaced())
            .padding(.horizontal, 3)
            .background((side == .before ? Color.red : Color.green).opacity(0.15),
                        in: RoundedRectangle(cornerRadius: 3))
            .accessibilityLabel("\(side == .before ? "Before" : "After"): \(text)")
    }
}
