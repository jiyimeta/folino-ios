import SwiftUI

/// Picker vocabulary for the Reader's per-staff clef override popover.
/// Each case carries its `NotatedClef.rawType`, its SMuFL codepoint
/// (Bravura PUA), and the staff line (1 = bottom, 5 = top) the clef
/// anchors to. The override map stores any rawType string, so future
/// expansion is purely additive here.
enum ClefMenuChoice: Hashable, CaseIterable {
    case trebleG, trebleG8va, trebleG8vb, trebleG15ma, trebleG15mb
    case bassF, bassF8va, bassF8vb
    case altoC3, tenorC4

    var rawType: String {
        switch self {
        case .trebleG: "G"
        case .trebleG8va: "G8va"
        case .trebleG8vb: "G8vb"
        case .trebleG15ma: "G15ma"
        case .trebleG15mb: "G15mb"
        case .bassF: "F"
        case .bassF8va: "F8va"
        case .bassF8vb: "F8vb"
        case .altoC3: "C3"
        case .tenorC4: "C4"
        }
    }

    /// SMuFL Private Use Area codepoint (Bravura). Source:
    /// https://www.smufl.org/version/latest/range/clefs/
    var smuflGlyph: Character {
        switch self {
        case .trebleG: "\u{E050}" // gClef
        case .trebleG8va: "\u{E053}" // gClef8va
        case .trebleG8vb: "\u{E052}" // gClef8vb
        case .trebleG15ma: "\u{E054}" // gClef15ma
        case .trebleG15mb: "\u{E051}" // gClef15mb
        case .bassF: "\u{E062}" // fClef
        case .bassF8va: "\u{E065}" // fClef8va
        case .bassF8vb: "\u{E064}" // fClef8vb
        case .altoC3, .tenorC4: "\u{E05C}" // cClef (movable)
        }
    }

    /// Localized accessibility label. Picker tiles render glyphs only;
    /// this label is what VoiceOver announces.
    var displayLabel: LocalizedStringKey {
        switch self {
        case .trebleG: "reader.preferences.clef.choice.treble"
        case .trebleG8va: "reader.preferences.clef.choice.treble8va"
        case .trebleG8vb: "reader.preferences.clef.choice.treble8vb"
        case .trebleG15ma: "reader.preferences.clef.choice.treble15ma"
        case .trebleG15mb: "reader.preferences.clef.choice.treble15mb"
        case .bassF: "reader.preferences.clef.choice.bass"
        case .bassF8va: "reader.preferences.clef.choice.bass8va"
        case .bassF8vb: "reader.preferences.clef.choice.bass8vb"
        case .altoC3: "reader.preferences.clef.choice.alto"
        case .tenorC4: "reader.preferences.clef.choice.tenor"
        }
    }

    static let trebleFamily: [ClefMenuChoice] = [
        .trebleG, .trebleG8va, .trebleG8vb, .trebleG15ma, .trebleG15mb,
    ]
    static let bassFamily: [ClefMenuChoice] = [
        .bassF, .bassF8va, .bassF8vb,
    ]
    static let cFamily: [ClefMenuChoice] = [
        .altoC3, .tenorC4,
    ]

    /// Looks up the menu choice for an arbitrary rawType. Returns
    /// `nil` for rawTypes outside the v1 picker (e.g. `"PERC"`).
    static func from(rawType: String) -> ClefMenuChoice? {
        allCases.first { $0.rawType == rawType }
    }
}
