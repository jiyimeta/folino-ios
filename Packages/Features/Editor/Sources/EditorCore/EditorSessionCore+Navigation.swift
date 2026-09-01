import Domain
import SheetMusicCore

/// The pad's ← / → keys. Tapping a notehead is the precise way to select; these step the selection along the voice
/// for everything else — walking off a dense chord, or moving on after an edit without re-aiming a finger.
///
/// Navigation only: no command is applied, so the score, the undo stack and `appliedEditCount` are untouched. At
/// either end of the staff the selection HOLDS rather than clearing — a key that empties the selection would leave
/// the rest of the pad inert, which reads as the app losing your place.
extension EditorSessionCore {
    public func selectPreviousElement() {
        step { ColumnNavigation.previous(before: $0, in: $1) }
    }

    public func selectNextElement() {
        step { ColumnNavigation.next(after: $0, in: $1, steppingBy: armedInputDuration) }
    }

    /// Steps from the CARET — the position marker, and the one thing on screen that says where you are — and lands
    /// selection and caret together: stepping is an explicit pick, so it re-syncs the two the same way a tap does.
    /// Falls back to the selection's slot when the caret has run off the end of the staff, so ← can still walk back.
    ///
    /// The walk is over COLUMNS, not over one voice's elements (drum note entry's §5.4): it stops wherever ANY
    /// voice of the staff has an onset, and → falls back to a step of the armed duration when nothing is written
    /// ahead in the bar — which is what makes an empty measure enterable. On a single-voice staff the union has one
    /// member per element and the walk lands exactly where the voice-bound one did.
    private func step(_ walk: (ScoreColumn, Score) -> ScoreColumn?) {
        guard let score, let location = Self.slot(of: caretItem) ?? Self.slot(of: selectedItem),
              let column = caretColumn ?? ColumnNavigation.column(of: location, in: score),
              let destination = walk(column, score)
        else { return }
        place(column: destination, preferring: location.voiceIndex)
        // Stepping is a pick, exactly as a tap is, so it sounds what it landed on — see
        // `auditionSelectionIfAudible`. Only after a step that MOVED: a key held at the end of the staff holds the
        // selection rather than clearing it, and re-sounding the same note per press would read as a stutter.
        auditionSelectionIfAudible()
    }
}
