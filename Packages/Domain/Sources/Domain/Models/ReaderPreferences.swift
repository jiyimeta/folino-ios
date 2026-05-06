import CoreGraphics
import Foundation
import SheetMusicCore

/// Per-score Reader display settings: engraved staff size and the set of
/// hidden staves (addressed by `(partIndex, staffIndexInPart)`). Layout
/// mode (vertical vs. page) is global and is NOT stored here — the Reader
/// feature reads it from `@AppStorage`.
public struct ReaderPreferences: Hashable, Sendable, Codable, Identifiable {
    public static let minStaffSize: CGFloat = 8
    public static let maxStaffSize: CGFloat = 28

    public let id: ReaderPreferencesID
    public let scoreItemID: ScoreItemID
    public var staffSize: CGFloat
    public var hiddenStaves: Set<StaffAddress>
    /// User-chosen GM program (0…127) per staff that overrides whatever the
    /// score declares. Absent entries fall back to the score's instrument
    /// channel program. Bank stays at 0 — the picker only swaps melodic
    /// programs (matches `swift-sheet-music`'s `ProgramMenu`).
    public var staffProgramOverrides: [StaffAddress: Int]

    public init(
        id: ReaderPreferencesID = ReaderPreferencesID(),
        scoreItemID: ScoreItemID,
        staffSize: CGFloat,
        hiddenStaves: Set<StaffAddress>,
        staffProgramOverrides: [StaffAddress: Int] = [:]
    ) {
        self.id = id
        self.scoreItemID = scoreItemID
        self.staffSize = min(max(staffSize, Self.minStaffSize), Self.maxStaffSize)
        self.hiddenStaves = hiddenStaves
        self.staffProgramOverrides = staffProgramOverrides.mapValues { min(max($0, 0), 127) }
    }
}
