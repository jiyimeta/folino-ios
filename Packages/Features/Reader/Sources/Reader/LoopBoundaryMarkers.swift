import CoreGraphics
import SheetMusicLayout
import SwiftUI

/// Returns the line rect and apex-right triangle path for the A endpoint
/// of an A–B loop, drawn at the **left edge** of `measureIndex`. Returns
/// nil if the measure is not present in any system of `document`.
func aMarkerGeometry(
    document: LayoutDocument,
    measureIndex: Int,
    triangleHeight: CGFloat,
    lineThickness: CGFloat,
    triangleWidth: CGFloat
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
        height: (systemBottom - systemTop) + triangleHeight
    )
    var triangle = Path()
    let baseTop = CGPoint(x: lineCenterX, y: systemTop - triangleHeight)
    let baseBottom = CGPoint(x: lineCenterX, y: systemTop)
    let apex = CGPoint(
        x: lineCenterX + triangleWidth,
        y: systemTop - triangleHeight / 2
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
    triangleWidth: CGFloat
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
        height: (systemBottom - systemTop) + triangleHeight
    )
    var triangle = Path()
    let baseTop = CGPoint(x: lineCenterX, y: systemTop - triangleHeight)
    let baseBottom = CGPoint(x: lineCenterX, y: systemTop)
    let apex = CGPoint(
        x: lineCenterX - triangleWidth,
        y: systemTop - triangleHeight / 2
    )
    triangle.move(to: baseTop)
    triangle.addLine(to: apex)
    triangle.addLine(to: baseBottom)
    triangle.closeSubpath()
    return (line, triangle)
}

private func locate(
    document: LayoutDocument, measureIndex: Int
) -> (system: LayoutSystem, measure: LayoutMeasure)? {
    for system in document.systems {
        if let measure = system.measures.first(where: { $0.measureIndex == measureIndex }) {
            return (system, measure)
        }
    }
    return nil
}
