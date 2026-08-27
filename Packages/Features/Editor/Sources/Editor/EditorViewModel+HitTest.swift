import Foundation
import SheetMusicCore
import SheetMusicLayout

/// Maps a tap point (in the Reader's score-surface / `LayoutDocument` coordinate space) to a selection via
/// `LayoutDocument.editingHitTest(at:activeVoice:)`. The Pencil hover pre-highlight reuses the same resolution,
/// unmutated.
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

    /// Pencil hover pre-highlight (spec §5.2): same resolution as `handleTap(at:)` but WITHOUT mutating
    /// selection — the Reader overlay draws a soft highlight at the returned item's anchor while the Pencil hovers,
    /// so the target is visible before the user commits with a tap.
    public func hoverItem(at point: CGPoint) -> SheetMusicCore.ScoreItemID? {
        resolvedItem(at: point)
    }

    /// Shared resolver behind `handleTap(at:)` and `hoverItem(at:)`. The policy — which targets are selectable, the
    /// 44x44 slop box, the active-voice preference (spec §5.5) and the on-staff gate that makes a tap on empty paper
    /// mean "nothing" — lives in `LayoutDocument.editingHitTest(at:activeVoice:)`, so Android's host runs the same
    /// one rather than a Kotlin retelling of it.
    ///
    /// What stays here is the addressing: the engine answers against the RENDERED document, which may be a
    /// staff-filtered rendition of the score this view model edits, so the result is re-stamped into source
    /// addressing before it leaves (`displayToSourceItem`, identity when nothing is filtered).
    private func resolvedItem(at point: CGPoint) -> SheetMusicCore.ScoreItemID? {
        displayedItem(at: point).flatMap(displayToSourceItem)
    }

    /// The hit itself, still in the rendered document's addressing.
    private func displayedItem(at point: CGPoint) -> SheetMusicCore.ScoreItemID? {
        documentProvider()?.editingHitTest(at: point, activeVoice: activeVoice)
    }
}
