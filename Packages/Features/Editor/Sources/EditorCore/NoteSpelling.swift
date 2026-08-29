import Domain
import Foundation
import SheetMusicCore

/// A note name taken apart: which letter, how far it is altered from that letter, and which scientific octave it
/// sits in.
///
/// The parts rather than the assembled string, because assembling is where the platforms differ — iOS joins them
/// with `String(localized:bundle:.module)`, Android from its own string resources under the same `editor.*` keys.
/// The math that produces them is the same on both, and is the same line-of-fifths reading `StaffStepPitch` does.
public struct NoteSpelling: Sendable, Equatable {
    /// 0 = C … 6 = B.
    public let letterIndex: Int
    /// …−2 (𝄫), −1 (♭), 0 (♮), +1 (♯), +2 (𝄪)… — how far the tpc sits from its natural letter.
    public let alteration: Int
    /// Scientific octave: 4 contains middle C.
    public let octave: Int

    public init(letterIndex: Int, alteration: Int, octave: Int) {
        self.letterIndex = letterIndex
        self.alteration = alteration
        self.octave = octave
    }
}

/// Spells a note from a MIDI pitch + tpc.
///
/// - Letter comes from the tpc's position on the line of fifths (shared math with `StaffStepPitch`).
/// - Accidental glyph comes from the tpc's alteration relative to its natural letter. The glyphs (`♯ ♭ 𝄪 𝄫`) travel
///   with the math rather than staying behind with the localized text: they are Unicode musical symbols, not
///   translatable words, and Android renders the same characters.
/// - Octave comes from the MIDI pitch, bucketed against the letter's natural pitch so enharmonic spellings land in
///   the letter's octave (B♯3 and C♭4 spell correctly, not B♯4 / C♭3). Octave 4 contains middle C (MIDI 60).
public enum NoteSpeller {
    /// Scientific-pitch letter for each diatonic index, `C D E F G A B` order.
    private static let letterNames = ["C", "D", "E", "F", "G", "A", "B"]
    /// Semitone offset of each natural letter from C, `C D E F G A B` order.
    private static let naturalSemitoneByLetter = [0, 2, 4, 5, 7, 9, 11]

    public static func spelling(pitch: Int, tpc: Int) -> NoteSpelling {
        let letter = letterIndex(forTpc: tpc)
        return NoteSpelling(
            letterIndex: letter,
            alteration: alteration(forTpc: tpc),
            octave: octave(pitch: pitch, letter: letter),
        )
    }

    /// `"E♭4"`. Natural notes carry no glyph (`"C4"`, not `"C♮4"`).
    public static func name(pitch: Int, tpc: Int) -> String {
        let parts = spelling(pitch: pitch, tpc: tpc)
        let glyph = accidentalGlyph(forAlteration: parts.alteration)
        return "\(letterNames[parts.letterIndex])\(glyph)\(parts.octave)"
    }

    /// The written length of whatever occupies `item`'s slot, or `nil` when the slot holds no timed element.
    public static func duration(for item: SheetMusicCore.ScoreItemID, in score: Score) -> NoteDuration? {
        let veID = VoiceElementID(
            staff: item.staff,
            measureIndex: item.measureIndex,
            voiceIndex: item.voiceIndex,
            elementIndex: item.elementIndex,
        )
        guard case let .chord(chord)? = score[veID] else { return nil }
        return chord.duration
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
}
