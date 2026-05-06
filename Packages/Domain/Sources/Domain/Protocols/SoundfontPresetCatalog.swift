import Foundation

/// Looks up the human-readable preset name for a `(bank, program)` pair.
/// Backed by the bundled SoundFont file's preset-header chunk so the
/// Settings cache UI can label every patch with the same name the
/// authoring tool uses (e.g. "Contrabass Expr." for bank 17 / program 43),
/// not just GM Level 1 names. Returns `nil` if the SoundFont doesn't
/// define that preset.
public protocol SoundfontPresetCatalog: Sendable {
    func presetName(bank: Int, program: Int) -> String?
}
