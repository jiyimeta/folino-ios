@testable import Domain
import Foundation
import Testing

/// The annotation half of the part add / remove / reorder migration, mirroring `ReaderPreferencesPartRemapTests`.
/// Every stroke carries the part index it was anchored to; a part operation renumbers those indices in the file, so
/// the stored ink has to be rewritten through the same `[oldPartIndex: newPartIndex?]` map the preferences row is.
@Suite("Annotation part remapping")
struct AnnotationPartRemapTests {
    private func anchor(part: Int, staff: Int = 0) -> MusicalAnchor {
        MusicalAnchor(
            measureIndex: 4, tickInMeasure: 240, partIndex: part, staffIndexInPart: staff,
            dxSp: 1.5, verticalOffsetSp: -2.25,
        )
    }

    private func stroke(part: Int, staff: Int = 0, bytes: UInt8 = 0xAB) -> DrawingAnchor {
        DrawingAnchor(kind: .musical(anchor(part: part, staff: staff)), encodedDrawing: Data([bytes]))
    }

    private func musicalAnchor(of drawing: DrawingAnchor) -> MusicalAnchor? {
        guard case let .musical(anchor) = drawing.kind else { return nil }
        return anchor
    }

    // MARK: - Reorder

    @Test
    func `a reorder moves each stroke to where its part went`() {
        let drawings = [stroke(part: 0), stroke(part: 1), stroke(part: 2)]
        // 0 → 2, 1 → 0, 2 → 1.
        let migrated = AnnotationLayers.remappingParts([0: 2, 1: 0, 2: 1], in: drawings)
        #expect(migrated.count == 3)
        #expect(migrated.map { musicalAnchor(of: $0)?.partIndex } == [2, 0, 1])
    }

    @Test
    func `everything but the part index rides through a reorder untouched`() {
        let original = stroke(part: 1, staff: 1, bytes: 0x5A)
        let migrated = AnnotationLayers.remappingParts([1: 0], in: [original])
        let anchor = migrated.first.flatMap(musicalAnchor)
        #expect(migrated.first?.id == original.id)
        #expect(migrated.first?.encodedDrawing == Data([0x5A]))
        #expect(anchor?.partIndex == 0)
        #expect(anchor?.staffIndexInPart == 1)
        #expect(anchor?.measureIndex == 4)
        #expect(anchor?.tickInMeasure == 240)
        #expect(anchor?.dxSp == 1.5)
        #expect(anchor?.verticalOffsetSp == -2.25)
    }

    // MARK: - Removal

    @Test
    func `a removed part takes its ink with it`() {
        let drawings = [stroke(part: 0), stroke(part: 1), stroke(part: 2)]
        let migrated = AnnotationLayers.remappingParts([0: nil, 1: 0, 2: 1], in: drawings)
        #expect(migrated.count == 2)
        #expect(migrated.map { musicalAnchor(of: $0)?.partIndex } == [0, 1])
    }

    @Test
    func `a part index the mapping does not mention is dropped, not passed through`() {
        let migrated = AnnotationLayers.remappingParts([0: nil, 1: 0], in: [stroke(part: 3)])
        #expect(migrated.isEmpty)
    }

    // MARK: - The covering scenario

    @Test
    func `a stroke on part 2 staff 1 lands on part 1 staff 1 when part 0 is removed`() {
        let migrated = AnnotationLayers.remappingParts(
            [0: nil, 1: 0, 2: 1], in: [stroke(part: 2, staff: 1)],
        )
        let anchor = musicalAnchor(of: migrated[0])
        #expect(anchor?.partIndex == 1)
        #expect(anchor?.staffIndexInPart == 1)
    }

    // MARK: - Page-anchored ink

    @Test
    func `page-anchored ink is untouched — a PDF page has no parts`() {
        let page = DrawingAnchor(kind: .page(PageAnchor(pageIndex: 3)), encodedDrawing: Data([0x01]))
        let migrated = AnnotationLayers.remappingParts([0: nil, 1: 0], in: [page])
        #expect(migrated.count == 1)
        #expect(migrated.first?.kind == .page(PageAnchor(pageIndex: 3)))
        #expect(migrated.first?.id == page.id)
    }

    @Test
    func `removing a part leaves the same item's page ink alone`() {
        let page = DrawingAnchor(kind: .page(PageAnchor(pageIndex: 0)), encodedDrawing: Data([0x02]))
        let migrated = AnnotationLayers.remappingParts([0: nil], in: [stroke(part: 0), page])
        #expect(migrated.count == 1)
        #expect(migrated.first?.kind.rendition == .originalPDF)
    }

    // MARK: - Identity and empties

    @Test
    func `an identity mapping changes nothing`() {
        let drawings = [stroke(part: 0), stroke(part: 1)]
        #expect(AnnotationLayers.remappingParts([0: 0, 1: 1], in: drawings) == drawings)
    }

    @Test
    func `an empty mapping drops everything musical`() {
        #expect(AnnotationLayers.remappingParts([:], in: [stroke(part: 0)]).isEmpty)
    }

    // MARK: - Text boxes

    @Test
    func `text boxes ride the same map`() {
        let boxes = [
            TextBoxAnchor(anchor: anchor(part: 0), text: "a"),
            TextBoxAnchor(anchor: anchor(part: 2, staff: 1), text: "b"),
        ]
        let migrated = AnnotationLayers.remappingParts([0: nil, 1: 0, 2: 1], in: boxes)
        #expect(migrated.count == 1)
        #expect(migrated.first?.text == "b")
        #expect(migrated.first?.anchor.partIndex == 1)
        #expect(migrated.first?.anchor.staffIndexInPart == 1)
    }
}
