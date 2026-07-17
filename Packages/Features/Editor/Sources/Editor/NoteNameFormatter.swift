import Foundation
import SheetMusicCore

/// Spells a note name from a MIDI pitch + tpc and assembles the selection readout shown in the iPad palette / iPhone
/// callout menu (spec §5.8) — e.g. `"E♭4 · 4分音符 · m.12 · 声部 1"`.
///
/// - Letter comes from the tpc's position on the line of fifths (shared math with `StaffStepPitch`).
/// - Accidental glyph comes from the tpc's alteration relative to its natural letter.
/// - Octave comes from the MIDI pitch, bucketed against the letter's natural pitch so enharmonic spellings land in
///   the letter's octave (B♯3 and C♭4 spell correctly, not B♯4 / C♭5). Octave 4 contains middle C (MIDI 60).
enum NoteNameFormatter {
    /// Scientific-pitch letter for each diatonic index, `C D E F G A B` order.
    private static let letterNames = ["C", "D", "E", "F", "G", "A", "B"]
    /// Semitone offset of each natural letter from C, `C D E F G A B` order.
    private static let naturalSemitoneByLetter = [0, 2, 4, 5, 7, 9, 11]

    /// `"E♭4"`. Natural notes carry no glyph (`"C4"`, not `"C♮4"`).
    static func name(pitch: Int, tpc: Int) -> String {
        let letter = letterIndex(forTpc: tpc)
        let glyph = accidentalGlyph(forAlteration: alteration(forTpc: tpc))
        return "\(letterNames[letter])\(glyph)\(octave(pitch: pitch, letter: letter))"
    }

    /// `"E♭4 · 4分音符 · m.12 · 声部 1"`. The note-name segment is present only for `.note` selections (a rest carries
    /// no pitch); duration / measure / voice segments follow. Segments that can't be resolved are dropped, so the
    /// separator never dangles.
    static func readout(for item: SheetMusicCore.ScoreItemID, in score: Score) -> String {
        var segments: [String] = []
        if case let .note(noteID) = item, let note = score[noteID] {
            segments.append(name(pitch: note.pitch, tpc: note.tpc))
        }
        if let duration = duration(for: item, in: score), let durationName = localizedDurationName(duration) {
            segments.append(durationName)
        }
        segments.append(String(
            format: String(localized: "editor.readout.measure", bundle: .module),
            item.measureIndex + 1,
        ))
        segments.append(String(
            format: String(localized: "editor.voice.n", bundle: .module),
            item.voiceIndex + 1,
        ))
        return segments.joined(separator: " · ")
    }

    /// Localized note-value name for the seven standard durations (reuses the pad's `editor.duration.*` keys); `nil`
    /// for irregular / measure / sub-64th durations that have no key.
    static func localizedDurationName(_ duration: NoteDuration) -> String? {
        let key: String.LocalizationValue
        switch duration {
        case .whole: key = "editor.duration.whole"
        case .half: key = "editor.duration.half"
        case .quarter: key = "editor.duration.quarter"
        case .eighth: key = "editor.duration.eighth"
        case .sixteenth: key = "editor.duration.sixteenth"
        case .thirtySecond: key = "editor.duration.thirtySecond"
        case .sixtyFourth: key = "editor.duration.sixtyFourth"
        default: return nil
        }
        return String(localized: key, bundle: .module)
    }

    // MARK: - Line-of-fifths helpers

    /// Diatonic letter index (0=C … 6=B) of a tpc. `(tpc + 1) % 7` rotates the line of fifths to align with
    /// `F C G D A E B`; the table maps that rotation back to `C D E F G A B` order.
    private static func letterIndex(forTpc tpc: Int) -> Int {
        let table = [3, 0, 4, 1, 5, 2, 6]
        return table[((tpc + 1) % 7 + 7) % 7]
    }

    /// Alteration in the range …−2 (𝄫), −1 (♭), 0 (♮), +1 (♯), +2 (𝄪)… — how far the tpc sits from its natural
    /// letter on the line of fifths (each ±7 tpc = one alteration step).
    private static func alteration(forTpc tpc: Int) -> Int {
        let centered = tpc - 13
        let posInFifths = ((centered % 7) + 7) % 7
        return (centered - posInFifths) / 7
    }

    private static func accidentalGlyph(forAlteration alteration: Int) -> String {
        switch alteration {
        case 0: return ""
        case 1: return "♯"
        case -1: return "♭"
        case 2: return "𝄪"
        case -2: return "𝄫"
        default:
            // Beyond double: repeat the single glyph (triple-sharp = "♯♯♯"). Rare, but keeps the readout total.
            let glyph = alteration > 0 ? "♯" : "♭"
            return String(repeating: glyph, count: abs(alteration))
        }
    }

    /// Scientific octave: bucket the pitch against the letter's natural pitch so the octave follows the letter, then
    /// subtract 1 (MIDI octave 5 = scientific octave 4, which contains middle C).
    private static func octave(pitch: Int, letter: Int) -> Int {
        let naturalSemi = naturalSemitoneByLetter[letter]
        let bucket = Int(((Double(pitch) - Double(naturalSemi)) / 12).rounded())
        return bucket - 1
    }

    private static func duration(for item: SheetMusicCore.ScoreItemID, in score: Score) -> NoteDuration? {
        let veID = VoiceElementID(
            staff: item.staff,
            measureIndex: item.measureIndex,
            voiceIndex: item.voiceIndex,
            elementIndex: item.elementIndex,
        )
        guard case let .chord(chord)? = score[veID] else { return nil }
        return chord.duration
    }
}

extension Bundle {
    /// The Editor module's resource bundle. Exposed (internal) so tests can perform locale-independent
    /// `String(localized:bundle:)` lookups against the same bundle the readout localizes through.
    static let editorModule = Bundle.module
}
