import SwiftUI

/// Picker vocabulary for the Reader's per-staff clef override popover. Each case carries its `NotatedClef.rawType`, its
/// SMuFL codepoint (Bravura PUA), and the staff line (1 = bottom, 5 = top) the clef anchors to. The override map stores
/// any rawType string, so future expansion is purely additive here.
enum ClefMenuChoice: Hashable, CaseIterable {
    case trebleG, trebleG8va, trebleG8vb, trebleG15ma, trebleG15mb
    case bassF, bassF8va, bassF8vb
    case sopranoC1, altoC3, tenorC4, baritoneC5
    case percussion, percussion2

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
        case .sopranoC1: "C1"
        case .altoC3: "C3"
        case .tenorC4: "C4"
        case .baritoneC5: "C5"
        case .percussion: "PERC"
        case .percussion2: "PERC2"
        }
    }

    /// SMuFL Private Use Area codepoint (Bravura). Source: https://www.smufl.org/version/latest/range/clefs/
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
        // All four C clef variants share the movable cClef glyph; the staff-line position the glyph attaches to is what
        // distinguishes Soprano (line 1) / Alto (3) / Tenor (4) / Baritone (5). The picker tile applies that yOffset
        // itself.
        case .sopranoC1, .altoC3, .tenorC4, .baritoneC5: "\u{E05C}" // cClef (movable)
        case .percussion: "\u{E069}" // unpitchedPercussionClef1
        case .percussion2: "\u{E06A}" // unpitchedPercussionClef2
        }
    }

    /// Localized accessibility label. Picker tiles render glyphs only; this label is what VoiceOver announces.
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
        case .sopranoC1: "reader.preferences.clef.choice.soprano"
        case .altoC3: "reader.preferences.clef.choice.alto"
        case .tenorC4: "reader.preferences.clef.choice.tenor"
        case .baritoneC5: "reader.preferences.clef.choice.baritone"
        case .percussion: "reader.preferences.clef.choice.percussion"
        case .percussion2: "reader.preferences.clef.choice.percussion2"
        }
    }

    static let trebleFamily: [ClefMenuChoice] = [
        .trebleG, .trebleG8va, .trebleG8vb, .trebleG15ma, .trebleG15mb,
    ]
    static let bassFamily: [ClefMenuChoice] = [
        .bassF, .bassF8va, .bassF8vb,
    ]
    static let cFamily: [ClefMenuChoice] = [
        .sopranoC1, .altoC3, .tenorC4, .baritoneC5,
    ]
    static let percussionFamily: [ClefMenuChoice] = [
        .percussion, .percussion2,
    ]

    /// True if this choice belongs to the percussion family. The picker uses this to keep percussion staves on
    /// percussion clefs and keep pitched staves on pitched clefs — overriding across families would produce nonsensical
    /// playback / engraving.
    var isPercussion: Bool {
        switch self {
        case .percussion, .percussion2: true
        default: false
        }
    }

    /// Looks up the menu choice for an arbitrary rawType. Returns `nil` for rawTypes outside the v1 picker.
    static func from(rawType: String) -> ClefMenuChoice? {
        allCases.first { $0.rawType == rawType }
    }
}
