import SwiftUI

/// Picker vocabulary for the Reader's per-staff clef override menu.
/// Constrains the v1 UI to ten clefs; the underlying override map
/// stores any `NotatedClef.rawType` string, so future expansion is
/// purely additive here.
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

    /// Localized label shown on the menu button and inside each
    /// menu row. Treble / Bass / Alto / Tenor are the conventional
    /// English names; the `8va` / `8vb` / `15ma` / `15mb` modifiers
    /// stay as universal music-notation symbols even when the rest
    /// of the string is localized.
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
    /// `nil` for rawTypes outside the v1 picker (e.g. `"PERC"`) — the
    /// menu renders these as a fallback label without highlighting any
    /// item.
    static func from(rawType: String) -> ClefMenuChoice? {
        allCases.first { $0.rawType == rawType }
    }
}
