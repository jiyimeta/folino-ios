import Foundation
import ReaderAnnotationCore
import Wirelet

#if !canImport(CoreGraphics)
/// Same rationale as `PdfAnnotationBridge.swift`: anchor to `ReaderAnnotationCore`'s own geometry stubs on Android so
/// this file's `CGRect` resolves to the one `PDFCursorProjection` operates on, not Foundation's CoreGraphics shim.
private typealias CGRect = ReaderAnnotationCore.CGRect
#endif

// swift-java (jextract) entry points for the Android Reader's on-PDF playback cursor. Pure delegation to the shared
// `PDFCursorProjection` so iOS and Android place the cursor over the original PDF with one implementation (parity —
// no divergent Kotlin port of the projection). The cursor rect itself comes from swift-sheet-music
// (`SheetMusicJNI.nativePdfCursorRect`, already top-left page space); Kotlin only supplies the frame the page
// currently occupies on its own surface and draws whatever comes back.

/// Place a side-car cursor rect into the frame its page currently occupies on the calling surface.
///
/// `cursorX` / `cursorY` / `cursorWidth` / `cursorHeight` are the fields of ssm's `PdfRectWire` — the cursor in that
/// page's own point space, top-left origin. `geometryPageWidthPt` is the same page's width from
/// `SheetMusicJNI.nativePdfPageSizes` (0 for a page whose size the importer never recorded — see `PdfPageSizesWire`).
/// `pageFrameBytes` is a `PageFrameWire`: the page's CURRENT frame in the surface's own content space, the same value
/// the annotation path already builds for `nativePdfAnnotationDisplayTransforms`.
///
/// Returns a `PageFrameWire` carrying the projected rect — deliberately the same wire type as the input, since both
/// are "an axis-aligned rect in the surface's content space" and Kotlin already has its codec (the same reuse
/// rationale `PdfAnnotationBridge` records for `StrokeTransformWire`). Empty `Data` means "do not draw the cursor
/// this frame": the page frame failed to decode, the side-car has no width for this page, or the page isn't laid out
/// (zero width — paged mode's placeholder for every off-screen page).
public func nativePdfCursorDisplayRect(
    cursorX: Double,
    cursorY: Double,
    cursorWidth: Double,
    cursorHeight: Double,
    geometryPageWidthPt: Double,
    pageFrameBytes: Data,
) -> Data {
    guard let frame = try? PageFrameWire(decoding: pageFrameBytes) else { return Data() }
    guard let placed = PDFCursorProjection.displayRect(
        cursorRect: CGRect(x: cursorX, y: cursorY, width: cursorWidth, height: cursorHeight),
        geometryPageWidthPt: geometryPageWidthPt,
        pageFrame: CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height),
    ) else { return Data() }

    return PageFrameWire(
        x: Double(placed.minX), y: Double(placed.minY),
        width: Double(placed.width), height: Double(placed.height),
    ).encodeToData()
}

/// Whether the Android renderer's own page width agrees with the OMR side-car's, both in PDF points. Pure delegation
/// to `PDFCursorProjection.pageWidthsAgree` so the tolerance lives in one place. A `false` is the caller's cue to
/// record a non-fatal once for the document and keep drawing — see that function's doc.
public func nativePdfPageWidthsAgree(renderedPageWidthPt: Double, geometryPageWidthPt: Double) -> Bool {
    PDFCursorProjection.pageWidthsAgree(
        renderedPageWidthPt: renderedPageWidthPt,
        geometryPageWidthPt: geometryPageWidthPt,
    )
}
