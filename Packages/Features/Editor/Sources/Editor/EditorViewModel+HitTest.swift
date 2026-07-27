import Foundation
import SheetMusicLayout
import SheetMusicUI

/// Task 8: maps a tap point (in the Reader's score-surface / `LayoutDocument` coordinate space) to a selection via
/// `ScoreHitTester`. Task 16 reuses the same resolution, unmutated, for the Pencil hover pre-highlight.
extension EditorViewModel {
    /// Tap in LayoutDocument coordinates (the Reader's score-surface space). Resolves via `resolvedItem(at:)` and
    /// applies it as the new selection (`nil` when nothing hit — spec §5.2: tap empty staff = deselect).
    public func handleTap(at point: CGPoint) {
        select(resolvedItem(at: point))
    }

    /// Task 16 (spec §5.2, Pencil hover pre-highlight): same resolution as `handleTap(at:)` but WITHOUT mutating
    /// selection — the Reader overlay draws a soft highlight at the returned item's anchor while the Pencil hovers,
    /// so the target is visible before the user commits with a tap.
    public func hoverItem(at point: CGPoint) -> SheetMusicCore.ScoreItemID? {
        resolvedItem(at: point)
    }

    /// Shared resolver behind `handleTap(at:)` and `hoverItem(at:)`:
    /// 1. `ScoreHitTester.hitTest(at:)` ladder (notehead → rest → beam → flag → stem → tuplet → clef).
    ///    `.stem`/`.flag`/`.beam` resolve to their first `NoteID`; `.clef` is ignored in v1 (no clef editing UI).
    /// 2. If the hit's `voiceIndex != activeVoice` and a 44x44 slop rect centered on `point` (via `itemIDs(in:)`)
    ///    contains an item of the active voice, prefer the first such item (spec §5.5 — the picker targets a
    ///    voice).
    /// 3. No hit → `nil`.
    private func resolvedItem(at point: CGPoint) -> SheetMusicCore.ScoreItemID? {
        guard let document = documentProvider() else { return nil }
        let tester = ScoreHitTester(document: document)
        let slop = Self.slopRect(around: point)

        guard let hit = tester.hitTest(at: point), let item = Self.selectableItem(from: hit) else {
            // The engine's ladder only answers for points inside an element's own geometry, which makes noteheads a
            // fingertip-sized target at best and a hairline one on a dense system. Fall back to anything within the
            // slop box so a near miss still lands, preferring the active voice the same way an on-target hit does.
            let nearby = tester.itemIDs(in: slop)
            return nearby.first { $0.voiceIndex == activeVoice } ?? nearby.first
        }

        if item.voiceIndex != activeVoice {
            if let preferred = tester.itemIDs(in: slop).first(where: { $0.voiceIndex == activeVoice }) {
                return preferred
            }
        }
        return item
    }

    /// Touch slop around a tap, in layout-document points. Used both to prefer the active voice on an on-target hit
    /// and to rescue a near miss — one constant so the two can't disagree about how close "close" is.
    private static func slopRect(around point: CGPoint) -> CGRect {
        let halfExtent: CGFloat = 22
        return CGRect(
            x: point.x - halfExtent, y: point.y - halfExtent,
            width: halfExtent * 2, height: halfExtent * 2,
        )
    }

    /// Reduces a raw hit-test target to the `ScoreItemID` that tapping it selects. `.stem`/`.flag`/`.beam` all
    /// select the first notehead they carry (there's no dedicated selection UI for those geometric elements yet);
    /// `.clef` has no v1 editing UI and is dropped.
    private static func selectableItem(from target: ScoreHitTarget) -> SheetMusicCore.ScoreItemID? {
        switch target {
        case let .note(id): .note(id)
        case let .rest(id): .rest(id)
        case let .tuplet(id): .tuplet(id)
        case let .stem(notes), let .flag(notes), let .beam(notes):
            notes.first.map(SheetMusicCore.ScoreItemID.note)
        case .clef:
            nil
        }
    }
}
