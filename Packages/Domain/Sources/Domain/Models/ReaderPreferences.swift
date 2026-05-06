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
    public static let minTempoMultiplier: Double = 0.5
    public static let maxTempoMultiplier: Double = 2.0

    public let id: ReaderPreferencesID
    public let scoreItemID: ScoreItemID
    public var staffSize: CGFloat
    public var hiddenStaves: Set<StaffAddress>
    /// User-chosen GM program (0…127) per staff that overrides whatever the
    /// score declares. Absent entries fall back to the score's instrument
    /// channel program. Bank stays at 0 — the picker only swaps melodic
    /// programs (matches `swift-sheet-music`'s `ProgramMenu`).
    public var staffProgramOverrides: [StaffAddress: Int]
    /// Per-score playback rate override. `nil` means "no override" — the
    /// engine plays at the score's native tempo. Set values are clamped to
    /// `[minTempoMultiplier, maxTempoMultiplier]`. The Reader's view model
    /// normalizes a saved value of exactly 1.0 back to `nil` so the
    /// override doesn't outlive the user's intent.
    public var tempoMultiplier: Double?
    /// Current repeat / loop mode for this score. Defaults to `.off`.
    public var repeatMode: RepeatMode
    /// Active A–B loop range. Only meaningful when `repeatMode == .abLoop`.
    /// `nil` when no range has been set.
    public var abRepeat: ABRepeatRange?

    public init(
        id: ReaderPreferencesID = ReaderPreferencesID(),
        scoreItemID: ScoreItemID,
        staffSize: CGFloat,
        hiddenStaves: Set<StaffAddress>,
        staffProgramOverrides: [StaffAddress: Int] = [:],
        tempoMultiplier: Double? = nil,
        repeatMode: RepeatMode = .off,
        abRepeat: ABRepeatRange? = nil
    ) {
        self.id = id
        self.scoreItemID = scoreItemID
        self.staffSize = min(max(staffSize, Self.minStaffSize), Self.maxStaffSize)
        self.hiddenStaves = hiddenStaves
        self.staffProgramOverrides = staffProgramOverrides.mapValues { min(max($0, 0), 127) }
        self.tempoMultiplier = tempoMultiplier.map {
            min(max($0, Self.minTempoMultiplier), Self.maxTempoMultiplier)
        }
        self.repeatMode = repeatMode
        self.abRepeat = abRepeat
    }

    private enum CodingKeys: String, CodingKey {
        case id, scoreItemID, staffSize, hiddenStaves, staffProgramOverrides
        case tempoMultiplier, repeatMode, abRepeat
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(ReaderPreferencesID.self, forKey: .id)
        let scoreItemID = try c.decode(ScoreItemID.self, forKey: .scoreItemID)
        let staffSize = try c.decode(CGFloat.self, forKey: .staffSize)
        let hiddenStaves = try c.decode(Set<StaffAddress>.self, forKey: .hiddenStaves)
        let overrides = try c.decodeIfPresent(
            [StaffAddress: Int].self, forKey: .staffProgramOverrides
        ) ?? [:]
        let tempo = try c.decodeIfPresent(Double.self, forKey: .tempoMultiplier)
        let mode = try c.decodeIfPresent(RepeatMode.self, forKey: .repeatMode) ?? .off
        let ab = try c.decodeIfPresent(ABRepeatRange.self, forKey: .abRepeat)
        self.init(
            id: id, scoreItemID: scoreItemID, staffSize: staffSize,
            hiddenStaves: hiddenStaves, staffProgramOverrides: overrides,
            tempoMultiplier: tempo, repeatMode: mode, abRepeat: ab
        )
    }
}
