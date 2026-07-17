import Foundation
import SheetMusicLayout
import SheetMusicUI

/// Task 8: maps a tap point (in the Reader's score-surface / `LayoutDocument` coordinate space) to a selection via
/// `ScoreHitTester`.
extension EditorViewModel {
    /// Tap in LayoutDocument coordinates (the Reader's score-surface space). Resolution:
    /// 1. `ScoreHitTester.hitTest(at:)` ladder (notehead → rest → beam → flag → stem → tuplet → clef).
    ///    `.stem`/`.flag`/`.beam` resolve to their first `NoteID`; `.clef` is ignored in v1 (no clef editing UI).
    /// 2. If the hit's `voiceIndex != activeVoice` and a 44x44 slop rect centered on `point` (via `itemIDs(in:)`)
    ///    contains an item of the active voice, prefer the first such item (spec §5.5 — the picker targets a
    ///    voice).
    /// 3. No hit → deselect (spec §5.2: tap empty staff = deselect).
    public func handleTap(at point: CGPoint) {
        guard let document = documentProvider() else {
            select(nil)
            return
        }
        let tester = ScoreHitTester(document: document)
        guard let hit = tester.hitTest(at: point), let item = Self.selectableItem(from: hit) else {
            select(nil)
            return
        }

        if item.voiceIndex != activeVoice {
            let slop = CGRect(x: point.x - 22, y: point.y - 22, width: 44, height: 44)
            if let preferred = tester.itemIDs(in: slop).first(where: { $0.voiceIndex == activeVoice }) {
                select(preferred)
                return
            }
        }
        select(item)
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
