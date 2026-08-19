import Domain
import Foundation
import SheetMusicCore

/// Read-only derived properties over selection / caret state. Split out of `EditorViewModel.swift` to keep that
/// file under SwiftLint's `file_length` budget (Task 1 review note) — these touch no private setters, so they can
/// live in an extension without issue.
extension EditorViewModel {
    /// Whether the pad has anything at all to act on. With neither a caret nor a selection there is no slot to write
    /// into and no item to edit, so every key is inert (there is nothing for one to mean).
    public var hasEditTarget: Bool {
        caretItem != nil || selectedItem != nil
    }

    /// Whether the SELECTION names a notehead — the shape ⌫ / ♯ / ♭ need. False for a rest, a tuplet bracket, or an
    /// empty selection, which is what gates those three keys: with the caret running ahead of the selection, "there
    /// is a caret" no longer implies "there is a note to sharpen".
    public var isNoteSelected: Bool {
        if case .note = selectedItem { true } else { false }
    }

    /// Whether the floating callout has anything to stand beside. The card is pinned to one timed slot and edits
    /// THAT slot's length, which a rest has exactly as a note does — so it shows for both, and only drops the pitch
    /// steps and the tie key on a rest (see `EditorCalloutView`). A tuplet bracket names no slot, and neither does
    /// an empty selection.
    public var hasSelectionCallout: Bool {
        Self.slot(of: selectedItem) != nil
    }
}
