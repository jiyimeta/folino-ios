import SwiftUI

/// A static, iPad-popover-styled floating card (rounded panel + upward arrow + shadow) used by the inspector screenshot
/// scenes to depict the Reader's `.popover`-presented inspectors.
///
/// We can't use the real `.popover(isPresented:)` here: a live popover is presented in the app *window's* coordinate
/// space, so inside the composed device thumbnail (only a sub-region of the capture window) it would escape the
/// thumbnail entirely. This view re-creates the popover's chrome statically so it renders deterministically in both
/// SwiftUI `#Preview` and the live UI-test capture, anchored within the thumbnail.
struct IPadPopoverCard<Content: View>: View {
    /// Trailing padding applied to the arrow so its tip lines up under the tapped toolbar icon (the inspector pill sits
    /// top-trailing in `ReaderToolbar`). Larger = arrow further from the card's right edge.
    var arrowTrailingPadding: CGFloat
    var width: CGFloat = 380
    var height: CGFloat = 600
    @ViewBuilder var content: () -> Content

    /// Matches the inspector form's grouped background so the arrow reads as a seamless extension of the card.
    private let surface = Color(.systemGroupedBackground)

    var body: some View {
        VStack(spacing: 0) {
            UpArrow()
                .fill(surface)
                .frame(width: 28, height: 14)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, arrowTrailingPadding)
            content()
                .frame(width: width, height: height)
                .background(surface)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .frame(width: width)
        .compositingGroup()
        .shadow(color: .black.opacity(0.22), radius: 24, y: 10)
    }
}

/// Upward-pointing triangle (apex centered at the top edge) for the popover arrow.
private struct UpArrow: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
