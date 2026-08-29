import Domain
import EditorCore
import Foundation
import SheetMusicCore

/// Every editing operation, forwarded to the core and mirrored back.
///
/// One shape, repeated: call the core, then `syncFromCore()`. The repetition is the point — it is what guarantees the
/// Observation state, the two seam callbacks, the preview and the autosave timer can never be skipped for one op and
/// not another, which is exactly the drift a hand-written mirror invites. The behavior itself is entirely in
/// `EditorSessionCore+*.swift`, where Android reaches it too.
///
/// The read-only queries below just read through; the core recomputes them from the same score the views are looking
/// at, and `generation` is what registers the Observation dependency that makes them re-run.
extension EditorViewModel {
    /// The general case of everything below: name an intent, mirror the result. Kept internal and un-narrowed
    /// because the session suite drives the choke point by name, and because an op the pad doesn't have a key for yet
    /// should not need a forwarder before it can be tested.
    @discardableResult
    func apply(_ intent: EditIntent) -> EditIntent? {
        defer { syncFromCore() }
        return core.apply(intent)
    }

    // MARK: - Input

    public func inputPitch(letter: Character) {
        core.inputPitch(letter: letter)
        syncFromCore()
    }

    public func deleteSelection() {
        core.deleteSelection()
        syncFromCore()
    }

    public func writeRest() {
        core.writeRest()
        syncFromCore()
    }

    public var canWriteRest: Bool {
        _ = generation
        return core.canWriteRest
    }

    public func setDuration(_ duration: NoteDuration) {
        core.setDuration(duration)
        syncFromCore()
    }

    public func toggleArmedDot() {
        core.toggleArmedDot()
        syncFromCore()
    }

    public func setArmedDots(_ dots: Int) {
        core.setArmedDots(dots)
        syncFromCore()
    }

    // MARK: - The selection's own length (the callout's copy of the length keys)

    public var selectedDuration: (base: NoteDuration, dots: Int)? {
        _ = generation
        return core.selectedDuration
    }

    public func setSelectionDuration(_ base: NoteDuration) {
        core.setSelectionDuration(base)
        syncFromCore()
    }

    public func setSelectionDots(_ dots: Int) {
        core.setSelectionDots(dots)
        syncFromCore()
    }

    public func toggleSelectionDot() {
        core.toggleSelectionDot()
        syncFromCore()
    }

    // MARK: - Pitch

    public func shiftPitch(bySemitones delta: Int) {
        core.shiftPitch(bySemitones: delta)
        syncFromCore()
    }

    public func shiftOctave(by octaves: Int) {
        core.shiftOctave(by: octaves)
        syncFromCore()
    }

    public func setAccidental(_ accidental: Accidental?) {
        core.setAccidental(accidental)
        syncFromCore()
    }

    // MARK: - Chords, ties, tuplets

    public func toggleAddToChord() {
        core.toggleAddToChord()
        syncFromCore()
    }

    public func removeSelectedNoteFromChord() {
        core.removeSelectedNoteFromChord()
        syncFromCore()
    }

    public func addIntervalNote(_ interval: DiatonicInterval) {
        core.addIntervalNote(interval)
        syncFromCore()
    }

    public var canTie: Bool {
        _ = generation
        return core.canTie
    }

    public var isSelectionTied: Bool {
        _ = generation
        return core.isSelectionTied
    }

    public func appendTiedNote() {
        core.appendTiedNote()
        syncFromCore()
    }

    public var canAppendTiedNote: Bool {
        _ = generation
        return core.canAppendTiedNote
    }

    public func toggleTie() {
        core.toggleTie()
        syncFromCore()
    }

    public var isCaretInTuplet: Bool {
        _ = generation
        return core.isCaretInTuplet
    }

    public func createTuplet(actualNotes: Int) {
        core.createTuplet(actualNotes: actualNotes)
        syncFromCore()
    }

    public func removeTuplet() {
        core.removeTuplet()
        syncFromCore()
    }

    // MARK: - Navigation

    public func selectPreviousElement() {
        core.selectPreviousElement()
        syncFromCore()
    }

    public func selectNextElement() {
        core.selectNextElement()
        syncFromCore()
    }

    // MARK: - Selection, driven from the hit test and the host

    /// Internal, for `EditorViewModel+HitTest.swift`.
    func select(_ item: SheetMusicCore.ScoreItemID?) {
        core.select(item)
        syncFromCore()
    }

    /// Internal, for `EditorViewModel+Measures.swift`'s append, which restores the two markers to what they named
    /// before the insert rather than letting the re-derivation move them onto the new last bar.
    func place(selection item: SheetMusicCore.ScoreItemID?, caret: SheetMusicCore.ScoreItemID?) {
        core.place(selection: item, caret: caret)
        syncFromCore()
    }

    /// Internal, for `EditorViewModel+HitTest.swift`. Selects and auditions in ONE core call, so the preview the
    /// core queues is drained by the same `syncFromCore()` that publishes the selection.
    func selectFromTap(_ item: SheetMusicCore.ScoreItemID?) {
        core.selectFromTap(item)
        syncFromCore()
    }
}
