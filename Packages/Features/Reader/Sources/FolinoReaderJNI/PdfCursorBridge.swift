import Foundation
import ReaderAnnotationCore
import Wirelet

#if !canImport(CoreGraphics)
/// Same rationale as `PdfAnnotationBridge.swift`: anchor to `ReaderAnnotationCore`'s own geometry stubs on Android so
/// this file's `CGRect` / `CGPoint` resolve to the ones `PDFCursorProjection` operates on, not Foundation's
/// CoreGraphics shim.
private typealias CGRect = ReaderAnnotationCore.CGRect
private typealias CGPoint = ReaderAnnotationCore.CGPoint
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

/// The OMR side-car's mediaBox widths (PDF points) positionally indexed by page, `0` for a page whose size the
/// importer never recorded — the array form of the `geometryPageWidthPt` scalar `nativePdfCursorDisplayRect` takes,
/// since resolving WHICH page a tap landed on needs all of them at once. Kotlin already holds exactly this array
/// (`PdfCursorProjector`'s own `geometryPageWidthsPt`, built from `SheetMusicJNI.nativePdfPageSizes`).
@WireFormat
public struct PdfPageWidthsWire: Equatable {
    public let widthsPt: [Double]

    public init(widthsPt: [Double]) {
        self.widthsPt = widthsPt
    }
}

/// A tap resolved onto the document: the page it landed on, plus that page's own point-space location (top-left
/// origin, y-down). Feed `pageIndex` / `x` / `y` straight to `SheetMusicJNI.nativePdfHitTest`.
@WireFormat
public struct PdfPageHitWire: Equatable {
    public let pageIndex: Int32
    public let x: Double
    public let y: Double

    public init(pageIndex: Int32, x: Double, y: Double) {
        self.pageIndex = pageIndex
        self.x = x
        self.y = y
    }
}

/// Resolve a tap at (`contentX`, `contentY`) in the calling surface's own content space — the SAME space
/// `pageFramesBytes` (a `PageFramesWire`) is expressed in, and the same space `nativePdfCursorDisplayRect` hands the
/// cursor back in — to the page under it plus that page's own point-space location.
///
/// The inverse of `nativePdfCursorDisplayRect`'s placement, delegating to the shared
/// `PDFCursorProjection.pageHit(contentPoint:geometryPageWidthsPt:pageFrames:)` so tap-to-seek and the cursor use one
/// implementation of the surface↔page mapping (parity — no divergent Kotlin port, in either direction). Kotlin only
/// has to invert its OWN camera (screen → content space), which is layout the two platforms differ on by design.
///
/// Empty `Data` means "this tap is not on any page": an input failed to decode, or the point landed in the
/// inter-page gutter / a letterbox margin / a page the side-car has no width for. Callers do nothing at all in that
/// case — no seek, and no feedback.
public func nativePdfTapPageHit(
    contentX: Double,
    contentY: Double,
    pageWidthsBytes: Data,
    pageFramesBytes: Data,
) -> Data {
    guard let widths = try? PdfPageWidthsWire(decoding: pageWidthsBytes),
          let frames = try? PageFramesWire(decoding: pageFramesBytes)
    else { return Data() }

    guard let hit = PDFCursorProjection.pageHit(
        contentPoint: CGPoint(x: contentX, y: contentY),
        geometryPageWidthsPt: widths.widthsPt,
        pageFrames: frames.frames.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) },
    ) else { return Data() }

    return PdfPageHitWire(
        pageIndex: Int32(hit.pageIndex), x: Double(hit.point.x), y: Double(hit.point.y),
    ).encodeToData()
}
