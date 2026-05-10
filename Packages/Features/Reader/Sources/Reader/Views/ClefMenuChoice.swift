import Foundation

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

    /// Short label shown in the menu row and on the menu's button label.
    var displayLabel: String {
        switch self {
        case .altoC3: "Alto"
        case .tenorC4: "Tenor"
        default: rawType
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
