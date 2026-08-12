import Domain
import EditorCore
import SheetMusicCore

/// The pad's ← / → keys. Tapping a notehead is the precise way to select; these step the selection along the voice
/// for everything else — walking off a dense chord, or moving on after an edit without re-aiming a finger.
///
/// Navigation only: no command is applied, so the score, the undo stack and `appliedEditCount` are untouched. At
/// either end of the staff the selection HOLDS rather than clearing — a key that empties the selection would leave
/// the rest of the pad inert, which reads as the app losing your place.
extension EditorViewModel {
    public func selectPreviousElement() {
        step { ElementNavigator.previousTimedElement(before: $0, in: $1) }
    }

    public func selectNextElement() {
        step { ElementNavigator.nextTimedElement(after: $0, in: $1) }
    }

    /// Steps from the CARET — the position marker, and the one thing on screen that says where you are — and lands
    /// selection and caret together: stepping is an explicit pick, so it re-syncs the two the same way a tap does.
    /// Falls back to the selection's slot when the caret has run off the end of the staff, so ← can still walk back.
    private func step(_ walk: (VoiceElementID, Score) -> VoiceElementID?) {
        guard let score, let location = Self.slot(of: caretItem) ?? Self.slot(of: selectedItem) else { return }
        guard let destination = walk(location, score) else { return }
        select(SelectionRederivation.item(at: destination, in: score, preferringNoteIndex: nil))
    }
}
