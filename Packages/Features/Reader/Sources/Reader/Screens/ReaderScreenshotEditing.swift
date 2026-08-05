import Foundation
import SheetMusicCore

/// Screenshot-capture support for note editing, second flavor after `ReaderRootScreen.isCaptureMode`.
///
/// The App Store capture harness swaps a marketing scene into the host app's window and draws it out — it never
/// drives the app — so it can neither press the edit button nor tap a note. The one state the note-editing shot
/// exists to show therefore has to be reachable from code, and this is the switch: set `readerAutoEditMeasure` and
/// `ReaderRootScreen` opens an edit session on that measure's first note as soon as the score has loaded. Absent the
/// key — every normal run — nothing here does anything.
///
/// Kept out of `ReaderRootScreen` so the screenshot path is one file rather than a scattering of members inside a
/// type already at its `type_body_length` budget.
enum ReaderScreenshotEditing {
    /// 0-based measure the capture wants an edit session on, or `nil` when this isn't a capture run.
    static var requestedMeasure: Int? {
        UserDefaults.standard.object(forKey: "readerAutoEditMeasure") as? Int
    }

    /// The first notehead in `measureIndex`, scanning staves top to bottom. Rests are chords with no notes
    /// (`VoiceElement`), so they are skipped — as is any staff resting through the whole bar, which is why this walks
    /// the staves rather than taking the topmost one: the first staff of a choral score is silent for bars at a time,
    /// and the shot wants a note the pitch and length keys can act on.
    static func firstSoundingNote(inMeasure measureIndex: Int, of score: Score) -> ScoreItemID? {
        for (partIndex, part) in score.parts.enumerated() {
            for (staffIndex, staff) in part.staves.enumerated() {
                guard staff.measures.indices.contains(measureIndex),
                      let voice = staff.measures[measureIndex].voices.first
                else { continue }
                for (elementIndex, element) in voice.elements.enumerated() {
                    guard case let .chord(chord) = element, !chord.notes.isEmpty else { continue }
                    return .note(NoteID(
                        staff: StaffAddress(partIndex: partIndex, staffIndexInPart: staffIndex),
                        measureIndex: measureIndex,
                        voiceIndex: 0,
                        elementIndex: elementIndex,
                        noteIndexInChord: 0,
                    ))
                }
            }
        }
        return nil
    }
}
