import Foundation
import SheetMusicCore

/// Per-score Reader display settings: engraved staff size and the set of hidden staves (addressed by `(partIndex,
/// staffIndexInPart)`). Layout mode (vertical vs. page) is global and is NOT stored here — the Reader feature reads it
/// from `@AppStorage`.
public struct ReaderPreferences: Hashable, Sendable, Codable, Identifiable {
    public static let minStaffSize: Double = 8
    public static let maxStaffSize: Double = 28
    public static let minTempoMultiplier = 0.5
    public static let maxTempoMultiplier = 2.0
    /// Master-output-volume bounds. `1.0` is unity (the score's authored mix, unchanged); the slider can boost up to
    /// `3.0` (300%) to compensate for quietly-authored scores or low-output soundfonts. A downstream peak limiter
    /// in the audio engine keeps the boost from hard-clipping.
    public static let minMasterVolume = 0.0
    public static let maxMasterVolume = 3.0
    /// Minimum run length (in measures) at which the Reader collapses consecutive empty-rest measures into a single
    /// H-bar. Fixed — not user-tunable in this iteration.
    public static let multiMeasureRestThreshold = 2

    /// Allow-list of canonical `NotatedClef.rawType` values the Domain initializer accepts. Mirrors the 14 forms
    /// `NotatedClef.rawType` emits in `swift-sheet-music`. Aliases that `NotatedClef(rawType:)` accepts as inputs but
    /// never emits (e.g. `"treble"`, `"bass"`, `"soprano"`, `"alto"`, `"tenor"`, `"baritone"`, `"G1"`, `"G2"`,
    /// `"percussion"`) are intentionally excluded so override values stay canonical and round-trip equality is
    /// preserved. If `swift-sheet-music` adds a new emitted rawType, audit `NotatedClef.rawType`'s switch and extend
    /// this set.
    static let knownClefRawTypes: Set = [
        "G", "G8va", "G8vb", "G15ma", "G15mb",
        "F", "F8va", "F8vb",
        "C1", "C3", "C4", "C5",
        "PERC", "PERC2",
    ]

    public let id: ReaderPreferencesID
    public let scoreItemID: ScoreItemID
    public var staffSize: Double
    public var hiddenStaves: Set<StaffAddress>
    /// User-chosen GM program (0…127) per staff that overrides whatever the score declares. Absent entries fall back to
    /// the score's instrument channel program. Bank stays at 0 — the picker only swaps melodic programs (matches
    /// `swift-sheet-music`'s `ProgramMenu`).
    public var staffProgramOverrides: [StaffAddress: Int]
    /// User-chosen volume `[0, 1]` per staff that overrides the score's mscx CC7. Absent entries fall back to the
    /// score's `InstrumentChannel.volume` (mapped from `0…127` to `0…1`), then to `1.0` if the score has no matching
    /// part. Matches the override-overlay shape of `staffProgramOverrides`.
    public var staffVolumeOverrides: [StaffAddress: Double]
    /// User-chosen display-only clef per staff that overrides the score's authored opening clef. Values are
    /// `NotatedClef.rawType` strings (e.g. `"G"`, `"G8vb"`, `"F8va"`, `"C3"`). Stored as `String` to avoid pulling
    /// `SheetMusicLayout` into Domain — the Reader feature converts via `NotatedClef(rawType:)` at the use site.
    /// Unknown rawTypes are dropped by the initializer.
    public var staffClefOverrides: [StaffAddress: String]
    /// Per-score playback rate override. `nil` means "no override" — the engine plays at the score's native tempo. Set
    /// values are clamped to `[minTempoMultiplier, maxTempoMultiplier]`. The Reader's view model normalizes a saved
    /// value of exactly 1.0 back to `nil` so the override doesn't outlive the user's intent.
    public var tempoMultiplier: Double?
    /// When `true` (default), the layout engine honors authored `<LayoutBreak>line` / `<LayoutBreak>page` markup, so
    /// the engraver's chosen system / page boundaries are reproduced. When `false`, the engine ignores both forms and
    /// wraps measures purely on the available view width — useful when the score was authored for a different page
    /// size.
    public var honorLayoutBreaks: Bool
    /// Current repeat / loop mode for this score. Defaults to `.off`.
    public var repeatMode: RepeatMode
    /// Active A–B loop range. Only meaningful when `repeatMode == .abLoop`. `nil` when no range has been set.
    public var abRepeat: ABRepeatRange?
    /// Per-score master output volume. `1.0` (default) is unity — the mix plays at the score's authored level.
    /// Boosts up to `maxMasterVolume` (300%) raise the whole mix past per-staff CC7's ceiling; the engine
    /// brick-wall-limits the result so a boost doesn't clip. Clamped to `[minMasterVolume, maxMasterVolume]`.
    public var masterVolume: Double

    public init(
        id: ReaderPreferencesID = ReaderPreferencesID(),
        scoreItemID: ScoreItemID,
        staffSize: Double,
        hiddenStaves: Set<StaffAddress>,
        staffProgramOverrides: [StaffAddress: Int] = [:],
        staffVolumeOverrides: [StaffAddress: Double] = [:],
        staffClefOverrides: [StaffAddress: String] = [:],
        tempoMultiplier: Double? = nil,
        honorLayoutBreaks: Bool = true,
        repeatMode: RepeatMode = .off,
        abRepeat: ABRepeatRange? = nil,
        masterVolume: Double = 1.0,
    ) {
        self.id = id
        self.scoreItemID = scoreItemID
        self.staffSize = min(max(staffSize, Self.minStaffSize), Self.maxStaffSize)
        self.hiddenStaves = hiddenStaves
        self.staffProgramOverrides = staffProgramOverrides.mapValues { min(max($0, 0), 127) }
        self.staffVolumeOverrides = staffVolumeOverrides.mapValues { min(max($0, 0), 1) }
        self.staffClefOverrides = staffClefOverrides.filter { _, raw in
            Self.knownClefRawTypes.contains(raw)
        }
        self.tempoMultiplier = tempoMultiplier.map {
            min(max($0, Self.minTempoMultiplier), Self.maxTempoMultiplier)
        }
        self.honorLayoutBreaks = honorLayoutBreaks
        self.repeatMode = repeatMode
        self.abRepeat = abRepeat
        self.masterVolume = min(max(masterVolume, Self.minMasterVolume), Self.maxMasterVolume)
    }

    private enum CodingKeys: String, CodingKey {
        case id, scoreItemID, staffSize, hiddenStaves, staffProgramOverrides
        case staffVolumeOverrides, tempoMultiplier, honorLayoutBreaks
        case repeatMode, abRepeat, masterVolume
        case staffClefOverrides
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(ReaderPreferencesID.self, forKey: .id)
        let scoreItemID = try c.decode(ScoreItemID.self, forKey: .scoreItemID)
        let staffSize = try c.decode(Double.self, forKey: .staffSize)
        let hiddenStaves = try c.decode(Set<StaffAddress>.self, forKey: .hiddenStaves)
        let programOverrides = try c.decodeIfPresent(
            [StaffAddress: Int].self, forKey: .staffProgramOverrides,
        ) ?? [:]
        let volumeOverrides = try c.decodeIfPresent(
            [StaffAddress: Double].self, forKey: .staffVolumeOverrides,
        ) ?? [:]
        let clefOverrides = try c.decodeIfPresent(
            [StaffAddress: String].self, forKey: .staffClefOverrides,
        ) ?? [:]
        let tempo = try c.decodeIfPresent(Double.self, forKey: .tempoMultiplier)
        let honorBreaks = try c.decodeIfPresent(Bool.self, forKey: .honorLayoutBreaks) ?? true
        let mode = try c.decodeIfPresent(RepeatMode.self, forKey: .repeatMode) ?? .off
        let ab = try c.decodeIfPresent(ABRepeatRange.self, forKey: .abRepeat)
        let master = try c.decodeIfPresent(Double.self, forKey: .masterVolume) ?? 1.0
        self.init(
            id: id, scoreItemID: scoreItemID, staffSize: staffSize,
            hiddenStaves: hiddenStaves, staffProgramOverrides: programOverrides,
            staffVolumeOverrides: volumeOverrides,
            staffClefOverrides: clefOverrides,
            tempoMultiplier: tempo,
            honorLayoutBreaks: honorBreaks, repeatMode: mode, abRepeat: ab,
            masterVolume: master,
        )
    }
}
