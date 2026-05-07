import Domain
import SheetMusicLayout
import SwiftUI

/// Translucent accent-color band drawn over the measures inside the
/// active A–B loop. Sized to the same `LayoutDocument` that
/// `ScoreView(document:score:...)` consumes — drop into the same
/// `ZStack` and the rectangles align with the rendered staves.
struct LoopRegionOverlay: View {
    let document: LayoutDocument
    let range: ABRepeatRange?

    var body: some View {
        Canvas { context, _ in
            guard let range else { return }
            let lower = range.start.measureIndex
            let upper = range.end.measureIndex
            for system in document.systems {
                for measure in system.measures
                    where measure.measureIndex >= lower
                    && measure.measureIndex <= upper
                {
                    let rect = CGRect(
                        x: system.origin.x + measure.origin.x,
                        y: system.origin.y,
                        width: measure.width,
                        height: system.size.height
                    )
                    context.fill(
                        Path(rect),
                        with: .color(.accentColor.opacity(0.15))
                    )
                }
            }
        }
        .frame(
            width: document.size.width,
            height: document.size.height,
            alignment: .topLeading
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
