import EditorCore
import SwiftUI

// `EditorPadTuckSide` and `EditorPadTuckGeometry` themselves live in `EditorCore`, so the thresholds and the release
// decisions are one implementation both platforms run — see the type's own doc for what the two deliberately do
// differently (how much of the card stays on screen when tucked). What stays here is the part that only means
// something to SwiftUI: the glyph.

extension EditorPadTuckSide {
    /// Points the way the pad will come out — inward, mirroring the PiP tab.
    var chevronSystemName: String {
        switch self {
        case .leading: "chevron.right"
        case .trailing: "chevron.left"
        }
    }
}

extension EditorPadTuckGeometry {
    /// The same rule, taking the `CGSize` a SwiftUI `GeometryReader` hands out. A different argument label, not an
    /// overload: `CGFloat` and `Double` convert implicitly, so same-labelled overloads would be ambiguous.
    static func threshold(in viewport: CGSize) -> CGFloat {
        threshold(viewportWidth: viewport.width, viewportHeight: viewport.height)
    }

    /// `DragGesture.Value.velocity` is a `CGSize`; the core takes the two components, because a size is a
    /// CoreGraphics type and the core is compiled for Android too.
    static func tuckDestination(
        translationX: CGFloat, projectedTranslationX: CGFloat, velocity: CGSize, threshold: CGFloat,
    ) -> EditorPadTuckSide? {
        tuckDestination(
            translationX: translationX,
            projectedTranslationX: projectedTranslationX,
            velocityX: velocity.width,
            velocityY: velocity.height,
            threshold: threshold,
        )
    }
}
