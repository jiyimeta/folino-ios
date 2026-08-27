import Foundation

/// Migrating a score's ANNOTATIONS through a change to its PARTS — the ink half of the rewrite
/// `ReaderPreferences+PartRemap.swift` performs for the per-score preferences row, and the same bug class.
///
/// Every stroke is pinned to a `MusicalAnchor`, which names its staff by part INDEX. Adding, removing or reordering a
/// part renumbers those indices in the file while the stored ink keeps pointing at the old numbers, so without this
/// rewrite deleting the top instrument leaves every annotation below it drawn over a different instrument's staff. The
/// strokes are not lost, which is what makes it insidious: they are misplaced, and the next capture bakes the wrong
/// position in permanently.
///
/// The mapping comes from `ScoreEditSession.partIndexMapping` — cumulative since the last consume point and derived by
/// diffing `Part.id`s, so undo and redo need no special handling — and is the SAME map the preferences row is migrated
/// through, consumed once for both.
extension AnnotationLayers {
    /// Rewrites every stroke's part index for a part add / remove / reorder. `mapping` covers every pre-edit part
    /// index; `nil` = the part was removed.
    ///
    /// **A removed part's ink goes with it.** Deleting an instrument deletes its music, so the fingering and the
    /// reminders written over that music have nothing left to describe — keeping them would mean re-pointing them at
    /// whatever part now sits at that index, which is precisely the corruption this exists to prevent. It matches what
    /// the preferences row does with the removed part's settings, and what the reader would see anyway: an anchor on a
    /// part that is gone no longer resolves, so `AnnotationAnchoring.display` already skips it and the next capture
    /// prunes it.
    ///
    /// A stroke whose `partIndex` the mapping does not mention at all is likewise DROPPED rather than passed through,
    /// for the reason `ReaderPreferences.remappingParts` documents: the old index is not a claim about the new
    /// numbering, and moving ink onto the wrong instrument is worse than losing it.
    ///
    /// `staffIndexInPart` — and the measure / tick / offset the rest of the anchor carries — are preserved: a part
    /// operation moves whole parts, it never re-shapes what is inside one. `id` and `encodedDrawing` ride through
    /// untouched, so a migrated stroke is the same stroke.
    public static func remappingParts(
        _ mapping: [Int: Int?], in drawings: [DrawingAnchor],
    ) -> [DrawingAnchor] {
        drawings.compactMap { $0.remappingParts(mapping) }
    }

    /// The same rewrite for the layer's text boxes. **Defensive, not a live guarantee:** the only writer,
    /// `AnnotationSaveCoordinator.persist`, encodes `textBoxes: []` unconditionally, so nothing reaches this today.
    /// The persisted body carries the field, though, and a migration that silently dropped it would be a data loss
    /// the day text boxes ship.
    public static func remappingParts(
        _ mapping: [Int: Int?], in textBoxes: [TextBoxAnchor],
    ) -> [TextBoxAnchor] {
        textBoxes.compactMap { $0.remappingParts(mapping) }
    }
}

extension DrawingAnchor {
    /// This stroke under `mapping`, or `nil` when its part did not survive. Page-anchored ink is returned unchanged —
    /// a PDF page has no parts, and an item read out of a PDF carries both renditions in the same array.
    func remappingParts(_ mapping: [Int: Int?]) -> DrawingAnchor? {
        switch kind {
        case let .musical(anchor):
            guard let migrated = anchor.remappingParts(mapping) else { return nil }
            return DrawingAnchor(id: id, kind: .musical(migrated), encodedDrawing: encodedDrawing)
        case .page:
            return self
        }
    }
}

extension TextBoxAnchor {
    /// This text box under `mapping`, or `nil` when its part did not survive.
    func remappingParts(_ mapping: [Int: Int?]) -> TextBoxAnchor? {
        guard let migrated = anchor.remappingParts(mapping) else { return nil }
        return TextBoxAnchor(id: id, anchor: migrated, text: text)
    }
}

extension MusicalAnchor {
    /// This anchor on its part's new index, or `nil` when the part was removed or the mapping does not mention it.
    /// Built through the memberwise `init`, so its clamping re-applies to the migrated anchor exactly as to a fresh
    /// one.
    func remappingParts(_ mapping: [Int: Int?]) -> MusicalAnchor? {
        // Double Optional: the outer level is "the mapping knows this index", the inner "the part survived".
        guard let mapped = mapping[partIndex], let destination = mapped else { return nil }
        return MusicalAnchor(
            measureIndex: measureIndex,
            tickInMeasure: tickInMeasure,
            partIndex: destination,
            staffIndexInPart: staffIndexInPart,
            dxSp: dxSp,
            verticalOffsetSp: verticalOffsetSp,
        )
    }
}
