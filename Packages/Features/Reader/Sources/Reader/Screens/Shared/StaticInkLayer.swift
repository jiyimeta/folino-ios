import PencilKit
import SwiftUI
import UIKit

/// Renders committed annotation ink as a static, non-interactive layer placed inside a paged reader's page content, so
/// the ink rides the page band's slide + zoom transforms. The viewport-pinned live canvas (used while actively
/// annotating) can only show the current page and cannot follow a page-turn slide — this layer fills that gap for
/// display.
///
/// The drawing is in band coordinates (`AnnotationAnchoring.displayPaged` / `PDFAnnotationAnchoring.displayPage`
/// output); `size` is the band (viewport) those coordinates live in. Rasterized with `PKDrawing.image(from:scale:)` (a
/// reliable, display-only render) at screen scale, so it is sharp at committed zoom 1 and softens under a pinch — the
/// same fidelity trade-off the paged page renderers make. Receives no touches, so it never competes with drawing /
/// tap-seek / page-swipe input.
struct StaticInkLayer: View {
    let drawing: PKDrawing
    let size: CGSize

    var body: some View {
        if drawing.strokes.isEmpty || size.width <= 0 || size.height <= 0 {
            Color.clear
        } else {
            Image(uiImage: drawing.image(from: CGRect(origin: .zero, size: size), scale: UIScreen.main.scale))
                .resizable()
                .frame(width: size.width, height: size.height)
                .allowsHitTesting(false)
        }
    }
}
