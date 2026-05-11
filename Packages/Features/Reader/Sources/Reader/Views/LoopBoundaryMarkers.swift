import CoreGraphics
import Domain
import SheetMusicLayout
import SwiftUI

/// Crisp accent-color line + filled triangle drawn at each endpoint of
/// an A–B loop. Each endpoint draws independently so a single marker
/// shows as soon as A or B is set, before the other has been chosen.
/// Shares the geometry plumbing of `LoopRegionOverlay` and is intended
/// to draw on top of it inside the score-surface `ZStack`.
struct LoopBoundaryMarkers: View {
    /// Multipliers applied to `document.metrics.sp` to derive marker
    /// dimensions. Exposed so tests can reference the same source of
    /// truth that the view draws with. Tune via the preview cases in
    /// `VerticalScoreContainerPreviews`.
    nonisolated static let triangleHeightFactor: CGFloat = 1.0
    nonisolated static let triangleWidthFactor: CGFloat = 1.2
    nonisolated static let lineThicknessFactor: CGFloat = 0.5

    let document: LayoutDocument
    let start: ChordPath?
    let end: ChordPath?

    var body: some View {
        Canvas { context, _ in
            let sp = document.metrics.sp
            let triangleHeight: CGFloat = sp * Self.triangleHeightFactor
            let triangleWidth: CGFloat = sp * Self.triangleWidthFactor
            let lineThickness: CGFloat = sp * Self.lineThicknessFactor

            if let start, let a = aMarkerGeometry(
                document: document,
                measureIndex: start.measureIndex,
                triangleHeight: triangleHeight,
                lineThickness: lineThickness,
                triangleWidth: triangleWidth,
            ) {
                context.fill(Path(a.line), with: .color(.accentColor))
                context.fill(a.triangle, with: .color(.accentColor))
            }
            if let end, let b = bMarkerGeometry(
                document: document,
                measureIndex: end.measureIndex,
                triangleHeight: triangleHeight,
                lineThickness: lineThickness,
                triangleWidth: triangleWidth,
            ) {
                context.fill(Path(b.line), with: .color(.accentColor))
                context.fill(b.triangle, with: .color(.accentColor))
            }
        }
        .frame(
            width: document.size.width,
            height: document.size.height,
            alignment: .topLeading,
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Returns the line rect and apex-right triangle path for the A endpoint
/// of an A–B loop, drawn at the **left edge** of `measureIndex`. Returns
/// nil if the measure is not present in any system of `document`.
func aMarkerGeometry(
    document: LayoutDocument,
    measureIndex: Int,
    triangleHeight: CGFloat,
    lineThickness: CGFloat,
    triangleWidth: CGFloat,
) -> (line: CGRect, triangle: Path)? {
    guard let hit = locate(document: document, measureIndex: measureIndex) else {
        return nil
    }
    let lineCenterX = hit.system.origin.x + hit.measure.origin.x
    let systemTop = hit.system.origin.y
    let systemBottom = hit.system.origin.y + hit.system.size.height
    let line = CGRect(
        x: lineCenterX - lineThickness / 2,
        y: systemTop - triangleHeight,
        width: lineThickness,
        height: (systemBottom - systemTop) + triangleHeight,
    )
    var triangle = Path()
    let baseTop = CGPoint(x: lineCenterX, y: systemTop - triangleHeight)
    let baseBottom = CGPoint(x: lineCenterX, y: systemTop)
    let apex = CGPoint(
        x: lineCenterX + triangleWidth,
        y: systemTop - triangleHeight / 2,
    )
    triangle.move(to: baseTop)
    triangle.addLine(to: apex)
    triangle.addLine(to: baseBottom)
    triangle.closeSubpath()
    return (line, triangle)
}

/// Returns the line rect and apex-left triangle path for the B endpoint
/// of an A–B loop, drawn at the **right edge** of `measureIndex`. Returns
/// nil if the measure is not present in any system of `document`.
func bMarkerGeometry(
    document: LayoutDocument,
    measureIndex: Int,
    triangleHeight: CGFloat,
    lineThickness: CGFloat,
    triangleWidth: CGFloat,
) -> (line: CGRect, triangle: Path)? {
    guard let hit = locate(document: document, measureIndex: measureIndex) else {
        return nil
    }
    let lineCenterX = hit.system.origin.x + hit.measure.origin.x + hit.measure.width
    let systemTop = hit.system.origin.y
    let systemBottom = hit.system.origin.y + hit.system.size.height
    let line = CGRect(
        x: lineCenterX - lineThickness / 2,
        y: systemTop - triangleHeight,
        width: lineThickness,
        height: (systemBottom - systemTop) + triangleHeight,
    )
    var triangle = Path()
    let baseTop = CGPoint(x: lineCenterX, y: systemTop - triangleHeight)
    let baseBottom = CGPoint(x: lineCenterX, y: systemTop)
    let apex = CGPoint(
        x: lineCenterX - triangleWidth,
        y: systemTop - triangleHeight / 2,
    )
    triangle.move(to: baseTop)
    triangle.addLine(to: apex)
    triangle.addLine(to: baseBottom)
    triangle.closeSubpath()
    return (line, triangle)
}

private func locate(
    document: LayoutDocument, measureIndex: Int,
) -> (system: LayoutSystem, measure: LayoutMeasure)? {
    for system in document.systems {
        if let measure = system.measures.first(where: { $0.measureIndex == measureIndex }) {
            return (system, measure)
        }
    }
    return nil
}
