import Domain
import Foundation
import ReaderAnnotationCore
import Wirelet

#if !canImport(CoreGraphics)
/// Same rationale as `AnnotationJNISymbols.swift`: anchor to `ReaderAnnotationCore`'s own geometry stubs on Android so
/// this file's `CGRect` resolves to the one `PageAnchoringCore` operates on, not Foundation's CoreGraphics shim.
private typealias CGRect = ReaderAnnotationCore.CGRect
#endif

// swift-java (jextract) entry points for Android PDF page-anchored annotation, the sibling of the musical-anchor
// bridge in `AnnotationJNISymbols.swift`. Both marshal Data in / Data out and delegate all geometry to a shared core
// (`PageAnchoringCore` here, `AnnotationAnchoringCore` there) — no math in Kotlin. Unlike the musical path, a page
// anchor needs no ssm round trip: the page index + frame are display-only inputs Kotlin already has (from its own
// PDF renderer), so there is no "resolve via SheetMusicJNI" step.
//
// Reusing `StrokeTransformWire` for display output is deliberate (see the parent plan): for a page anchor, `sp` is
// the page frame's width and `(px, py)` its origin — exactly the scale-then-translate the Android dry overlay already
// applies with `canvas.concat`. Kotlin's placement code needs no new type and no new code path.

/// One PDF page's content-space frame (document points), positionally indexed by page. Kotlin builds this from its
/// own PDF renderer's page layout.
@WireFormat
public struct PageFrameWire: Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// The current page layout for a whole PDF, positionally aligned with page index. Input to
/// `nativePdfAnnotationDisplayTransforms`.
@WireFormat
public struct PageFramesWire: Equatable {
    public let frames: [PageFrameWire]

    public init(frames: [PageFrameWire]) {
        self.frames = frames
    }
}

/// Capture one wet stroke, already known to belong to `pageIndex` (Kotlin resolves which page the user was drawing
/// on), into a persistable `.page` `DrawingAnchorWire`. `strokeBytes` is neutral `InkStroke` FINK bytes (from
/// `nativeEncodeInkStroke`); `pageFrameBytes` is that page's current content-space frame. Normalizes the stroke to a
/// fraction of the page's own width via `PageAnchoringCore.capturePage`, so it re-renders correctly at any zoom.
/// Empty `Data` when an input doesn't decode or the page frame has non-positive width (undefined normalization).
public func nativePdfAnnotationCapture(strokeBytes: Data, pageIndex: Int32, pageFrameBytes: Data) -> Data {
    guard let stroke = try? InkStrokeCodec.decode(strokeBytes),
          let frame = try? PageFrameWire(decoding: pageFrameBytes)
    else { return Data() }

    let pageFrame = CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
    guard let drawing = PageAnchoringCore.capturePage(
        strokes: [stroke], pageIndex: Int(pageIndex), pageFrame: pageFrame,
    ).first else { return Data() }

    return DrawingAnchorWire.page(pageIndex: pageIndex, encodedDrawing: drawing.encodedDrawing).encodeToData()
}

/// Compute the display transform for a whole layer in one call, positionally aligned with the input.
/// `drawingsBytes` = `[DrawingAnchorWire]` (what capture produced / Room stored, `.musical` and `.page` anchors
/// possibly mixed); `pageFramesBytes` = `PageFramesWire`, the PDF's current page layout. `sp == 0` marks a drawing
/// that isn't currently placeable this frame — a `.musical` wire (this path only ever draws page anchors; see
/// `AnchorKindWireCoding`'s doc comment for why `anchorKind` must gate this, not just `PageAnchor`'s own
/// negative-clamping `init`), or a `.page` wire whose page isn't in `pageFramesBytes` — matching the musical path's
/// own "unresolved this frame" convention. Empty `Data` if either input fails to decode.
public func nativePdfAnnotationDisplayTransforms(drawingsBytes: Data, pageFramesBytes: Data) -> Data {
    guard let wires = try? [DrawingAnchorWire](decoding: drawingsBytes),
          let pageFrames = try? PageFramesWire(decoding: pageFramesBytes)
    else { return Data() }

    let drawings = wires.map { wire in
        DrawingAnchor(
            kind: AnchorKindWireCoding.kind(
                anchorKind: wire.anchorKind, pageIndex: wire.pageIndex,
                measureIndex: wire.measureIndex, tickInMeasure: wire.tickInMeasure,
                partIndex: wire.partIndex, staffIndexInPart: wire.staffIndexInPart,
                dxSp: wire.dxSp, verticalOffsetSp: wire.verticalOffsetSp,
            ),
            encodedDrawing: wire.encodedDrawing,
        )
    }
    let frames = pageFrames.frames.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
    let transforms = PageAnchoringCore.displayStrokeTransforms(drawings, pageFrames: frames)

    let out = transforms.map { transform -> StrokeTransformWire in
        guard let transform else { return StrokeTransformWire(sp: 0, px: 0, py: 0) }
        return StrokeTransformWire(sp: Double(transform.sp), px: Double(transform.px), py: Double(transform.py))
    }
    return out.encodeToData()
}
