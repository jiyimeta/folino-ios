import EditorCore
import Foundation
import SheetMusicCore

/// Assembles the selection readout shown in the iPad palette / iPhone callout menu (spec §5.8) — e.g.
/// `"E♭4 · 4分音符 · m.12 · 声部 1"`.
///
/// The spelling math moved to `EditorCore.NoteSpeller` so Android can run it; what stays here is the part that
/// cannot cross a `.so` boundary — `String(localized:bundle:.module)`, which needs an xcstrings bundle. Android
/// assembles the same segments from its own string resources under the same `editor.*` keys.
enum NoteNameFormatter {
    /// `"E♭4"`. Natural notes carry no glyph (`"C4"`, not `"C♮4"`).
    static func name(pitch: Int, tpc: Int) -> String {
        NoteSpeller.name(pitch: pitch, tpc: tpc)
    }

    /// `"E♭4 · 4分音符 · m.12 · 声部 1"`. The note-name segment is present only for `.note` selections (a rest carries
    /// no pitch); duration / measure / voice segments follow. Segments that can't be resolved are dropped, so the
    /// separator never dangles.
    static func readout(for item: SheetMusicCore.ScoreItemID, in score: Score) -> String {
        var segments: [String] = []
        if case let .note(noteID) = item, let note = score[noteID] {
            segments.append(name(pitch: note.pitch, tpc: note.tpc))
        }
        if let duration = NoteSpeller.duration(for: item, in: score),
           let durationName = localizedDurationName(duration)
        {
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
}

extension Bundle {
    /// The Editor module's resource bundle. Exposed (internal) so tests can perform locale-independent
    /// `String(localized:bundle:)` lookups against the same bundle the readout localizes through.
    static let editorModule = Bundle.module
}
