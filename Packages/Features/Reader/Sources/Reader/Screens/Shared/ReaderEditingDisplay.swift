import SheetMusicCore

/// The score a screen ENGRAVES while note editing, and the key that says which edit it is — shared by
/// `ReaderRootScreen` (iOS) and `MacScoreContentView` (macOS) so the two can never disagree about it.
///
/// Three display transforms survive into an edit session — clef overrides, the written-pitch view, and the hidden-
/// staves filter — because each is one a `StaffAddress` remap can undo (`ReaderEditingHost` re-stamps IDs across the
/// filter). The two that renumber ELEMENTS within a staff — the global transpose and multi-measure-rest collapse — do
/// not: they would invalidate every positional ID the editor holds. So the transpose is pinned to 0 here, and the
/// caller passes `collapseMultiMeasureRests: false` to the containers while `score(…)` is non-nil.
@MainActor
enum ReaderEditingDisplay {
    /// The edited score with the survivable transforms applied, or `nil` when there is no editing session.
    static func score(
        host: ReaderEditingHost?,
        clefOverrides: [StaffAddress: String],
        hiddenStaves: Set<StaffAddress>,
    ) -> Score? {
        guard let host, host.isEditing, let edited = host.editedScore else { return nil }
        return ReaderDisplayTransforms.display(
            edited,
            clefOverrides: clefOverrides,
            transposeSemitones: 0,
            hiddenStaves: hiddenStaves,
        )
    }

    /// Which edit `score(…)` is — the containers' relayout key. Read HERE, beside the score, so the two always travel
    /// together: a container that read `editGeneration` itself advanced its key before the new score arrived and
    /// quietly re-engraved the previous edit (see the doc on `ReaderRootScreen.editingScoreVersion`'s history).
    static func version(host: ReaderEditingHost?) -> Int {
        guard let host, host.isEditing else { return 0 }
        return host.editGeneration
    }
}
