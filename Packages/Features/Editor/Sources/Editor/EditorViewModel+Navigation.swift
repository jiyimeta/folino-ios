import Domain
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

    private func step(_ walk: (VoiceElementID, Score) -> VoiceElementID?) {
        guard let score, let location = Self.voiceElement(of: selectedItem) else { return }
        guard let destination = walk(location, score) else { return }
        select(SelectionRederivation.item(at: destination, in: score, preferringNoteIndex: nil))
    }

    /// The voice slot a selected item occupies. Tuplet brackets (and clefs, which never reach the selection) don't
    /// name a single slot, so stepping from one is a no-op rather than a guess.
    private static func voiceElement(of item: SheetMusicCore.ScoreItemID?) -> VoiceElementID? {
        switch item {
        case let .note(id): VoiceElementID(id)
        case let .rest(id): VoiceElementID(id)
        case .tuplet, .clef, .none: nil
        }
    }
}
