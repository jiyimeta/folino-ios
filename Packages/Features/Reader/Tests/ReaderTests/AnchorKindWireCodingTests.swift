import Domain
import Foundation
@testable import ReaderAnnotationCore
import Testing

/// Covers the wire-field ↔ `DrawingAnchorKind` mapping `FolinoReaderJNI`'s `PdfAnnotationBridge` and
/// `AnnotationSaveBridge` both delegate to. Host-tested here because `FolinoReaderJNI` itself can only be verified
/// via the real Android arm64 cross-compile (see `AnchorKindWireCoding`'s doc comment) — this is the regression
/// coverage for the bug where a musical wire (the default `anchorKind == 0`, `pageIndex == -1`) was coerced into
/// `.page(pageIndex: 0)` because `PageAnchor.init` clamps negative indices to zero.
struct AnchorKindWireCodingTests {
    private func musicalAnchor() -> MusicalAnchor {
        MusicalAnchor(
            measureIndex: 2, tickInMeasure: 480, partIndex: 0, staffIndexInPart: 1, dxSp: 1.5, verticalOffsetSp: -3,
        )
    }

    @Test func `musical wire fields decode to a musical kind`() {
        let kind = AnchorKindWireCoding.kind(
            anchorKind: AnchorKindWireCoding.musicalAnchorKind, pageIndex: -1,
            measureIndex: 2, tickInMeasure: 480, partIndex: 0, staffIndexInPart: 1,
            dxSp: 1.5, verticalOffsetSp: -3,
        )
        #expect(kind == .musical(musicalAnchor()))
    }

    @Test func `page wire fields decode to a page kind, ignoring the zeroed musical fields`() {
        let kind = AnchorKindWireCoding.kind(
            anchorKind: AnchorKindWireCoding.pageAnchorKind, pageIndex: 3,
            measureIndex: 0, tickInMeasure: 0, partIndex: 0, staffIndexInPart: 0,
            dxSp: 0, verticalOffsetSp: 0,
        )
        #expect(kind == .page(PageAnchor(pageIndex: 3)))
    }

    /// The exact regression: a default/unset musical wire (`anchorKind == 0`, the wire's documented default) must
    /// NOT become `.page(pageIndex: 0)` just because `pageIndex`'s `-1` placeholder clamps to zero somewhere
    /// downstream.
    @Test func `a wire with the default musical anchorKind never decodes to a page kind`() {
        let kind = AnchorKindWireCoding.kind(
            anchorKind: AnchorKindWireCoding.musicalAnchorKind, pageIndex: -1,
            measureIndex: 0, tickInMeasure: 0, partIndex: 0, staffIndexInPart: 0,
            dxSp: 0, verticalOffsetSp: 0,
        )
        guard case .musical = kind else {
            Issue.record("expected .musical, got \(kind)")
            return
        }
    }

    @Test func `wireFields and kind round trip for musical`() {
        let kind = DrawingAnchorKind.musical(musicalAnchor())
        let fields = AnchorKindWireCoding.wireFields(for: kind)
        #expect(fields.anchorKind == AnchorKindWireCoding.musicalAnchorKind)
        #expect(fields.pageIndex == -1)
        #expect(AnchorKindWireCoding.kind(fields) == kind)
    }

    @Test func `wireFields and kind round trip for page`() {
        let kind = DrawingAnchorKind.page(PageAnchor(pageIndex: 7))
        let fields = AnchorKindWireCoding.wireFields(for: kind)
        #expect(fields.anchorKind == AnchorKindWireCoding.pageAnchorKind)
        #expect(fields.pageIndex == 7)
        #expect(AnchorKindWireCoding.kind(fields) == kind)
    }
}
