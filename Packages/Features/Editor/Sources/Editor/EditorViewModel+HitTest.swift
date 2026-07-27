import Foundation
import SheetMusicLayout
import SheetMusicUI

/// Task 8: maps a tap point (in the Reader's score-surface / `LayoutDocument` coordinate space) to a selection via
/// `ScoreHitTester`. Task 16 reuses the same resolution, unmutated, for the Pencil hover pre-highlight.
extension EditorViewModel {
    /// Tap in LayoutDocument coordinates (the Reader's score-surface space). Resolves via `resolvedItem(at:)` and
    /// applies it as the new selection (`nil` when nothing hit — spec §5.2: tap empty staff = deselect).
    public func handleTap(at point: CGPoint) {
        let item = resolvedItem(at: point)
        select(item)
        // Sound what was tapped, exactly as tapping the score does outside edit mode (`setManualCursor` auditions
        // there). Hearing the note you just aimed at is half of how you know you hit the right one — and it would be
        // odd for the same tap to speak on one screen and go silent on the other. Never over a running transport,
        // for the same reason the seek path doesn't: a one-shot preview on top of continuous playback.
        if case let .note(noteID)? = item, !isPlaybackActive {
            audition(noteID)
        }
    }

    /// Selects `item` outright — used to carry a selection made outside edit mode (a tap-to-seek on the score) into
    /// the session that follows, so entering edit mode picks up where the reader's finger left off instead of
    /// starting blank. Ignores an item the current score doesn't contain: positional IDs go stale, and the score may
    /// have moved on between that tap and this session.
    public func selectItem(_ item: SheetMusicCore.ScoreItemID?) {
        guard let item, let score, let slot = Self.slot(of: item), score[slot] != nil else {
            select(nil)
            return
        }
        select(item)
    }

    /// A tap on the paper outside the engraved area. Same outcome as a tap on empty staff space — nothing is
    /// selected — but it arrives without coordinates, since the surface that catches it isn't in document space.
    public func deselect() {
        select(nil)
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
            //
            // But only ON a staff. The slop box is 44 document points — several staff spaces at a typical staff size
            // — so away from this guard it reached out of the page margins and the gaps between systems and pulled in
            // whatever note was nearest. Tapping empty paper then re-selected instead of deselecting, and there was
            // no way to put the pad away short of leaving edit mode.
            guard isOnStaff(point, in: document) else { return nil }
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

    /// Whether `point` is close enough to a staff for the near-miss rescue to mean anything: inside the five lines,
    /// or within the same slop the rescue itself reaches, so ledger-line notes and stems still count. Anything
    /// further out — page margins, the gap between systems — is empty paper, where a tap means "nothing" rather than
    /// "whatever note is nearest".
    ///
    /// Deliberately measured with `slopHalfExtent`, the same number the box uses: a gate tighter than the box it
    /// guards would refuse rescues the box was built to make, and a looser one would let the rescue reach where the
    /// box can't.
    private func isOnStaff(_ point: CGPoint, in document: LayoutDocument) -> Bool {
        let staffHeight = document.metrics.staffHeight
        for system in document.systems {
            for origin in system.staffOrigins {
                let top = system.origin.y + origin.y
                if point.y >= top - Self.slopHalfExtent, point.y <= top + staffHeight + Self.slopHalfExtent {
                    return true
                }
            }
        }
        return false
    }

    /// How close "close" is, in layout-document points — for the slop box below and for `isOnStaff` above.
    private static let slopHalfExtent: CGFloat = 22

    /// Touch slop around a tap, in layout-document points. Used both to prefer the active voice on an on-target hit
    /// and to rescue a near miss — one constant so the two can't disagree about how close "close" is.
    private static func slopRect(around point: CGPoint) -> CGRect {
        CGRect(
            x: point.x - slopHalfExtent, y: point.y - slopHalfExtent,
            width: slopHalfExtent * 2, height: slopHalfExtent * 2,
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
