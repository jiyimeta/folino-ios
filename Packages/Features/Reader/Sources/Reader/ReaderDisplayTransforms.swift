import Domain

/// The display-only transform chain every Reader rendering path shares, in the one order that is correct.
///
/// Three call sites render a score — `ReaderViewModel.recomputeVisibleScore` (the on-screen reader),
/// `ReaderPiPSession.performArm` (the Picture-in-Picture frame) and `ReaderRootScreen.editingScore` (the page under
/// an edit session). They used to spell the chain out individually and drifted apart the moment a link was added;
/// they all go through here now so a new transform lands on every surface at once.
///
/// Order is load-bearing:
///
/// 1. **clef overrides** first — they are keyed by full-score `StaffAddress`, so they have to land before the
///    hidden-staves filter renumbers anything.
/// 2. **written-pitch view** next — a per-part shift, so it must run while every part is still addressable and
///    before the global transpose folds a second offset on top.
/// 3. **global transpose** — one offset for the whole score, chosen from the keys the written view produced.
/// 4. **hidden staves** last — the only step that renumbers `StaffAddress`.
///
/// Every step preserves element count, ordering, IDs and ticks within a staff, so the playback cursor translation
/// downstream is unaffected. **The result is for RENDERING only.** It must never reach playback, MIDI export or a
/// save path: `writtenPitchView()` shifts a transposing part's notes and keys, and the MSCX encoder applies that
/// part's offset itself, so encoding this score would shift every key and tpc a second time — silently, and
/// compounding on each save.
enum ReaderDisplayTransforms {
    /// - Parameter transposeSemitones: the reader's global transpose. Pass `0` for the editing path — the
    ///   written-pitch view still applies there, but a global transpose renumbers ELEMENTS within a staff, which no
    ///   staff remap can undo.
    static func display(
        _ score: Score,
        clefOverrides: [StaffAddress: String],
        transposeSemitones: Int,
        hiddenStaves: Set<StaffAddress>,
    ) -> Score {
        score
            .applying(clefOverrides: clefOverrides)
            .writtenPitchView()
            .transposed(bySemitones: transposeSemitones)
            .filtered(hidingStaves: hiddenStaves)
    }
}
