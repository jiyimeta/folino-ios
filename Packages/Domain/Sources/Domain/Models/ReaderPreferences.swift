import Foundation
import SheetMusicCore

/// Per-score Reader display settings: engraved staff size and the set of hidden staves (addressed by `(partIndex,
/// staffIndexInPart)`). Layout mode (vertical vs. page) is global and is NOT stored here — the Reader feature reads it
/// from `@AppStorage`.
///
/// The Optional scalar fields carry a third state beyond their value range: `nil` means the user never touched the
/// setting, so it resolves to whatever the current default is (read it through the matching `effective…` accessor).
/// A stored value — even one equal to the default — means the user chose it, and must survive every clamp / re-seat /
/// save round-trip. That is why clamping is `Optional.map`-based: a clamp that materialized a number out of `nil`
/// would silently mark the score as touched.
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

    /// Defaults an untouched (`nil`) field resolves to. Staff size has NO static default here — its default is the one
    /// that becomes device-class-dependent (`ReaderRootScreen`), so resolution takes it as an argument instead.
    public static let defaultHonorLayoutBreaks = true
    public static let defaultMasterVolume = 1.0
    public static let defaultTransposeSemitones = 0

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
    /// Engraved staff size in mm. `nil` = the user never chose one, so the Reader resolves it to the current default
    /// (which is device-class-dependent) via `effectiveStaffSize(default:)`. A stored value — including one that
    /// happens to equal the default — means the user chose it, and survives every re-seat/clamp/save round-trip.
    public var staffSize: Double?
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
    /// size. `nil` = the user never chose, so it resolves to `defaultHonorLayoutBreaks` via
    /// `effectiveHonorLayoutBreaks`.
    public var honorLayoutBreaks: Bool?
    /// Current repeat / loop mode for this score. Defaults to `.off`.
    public var repeatMode: RepeatMode
    /// Active A–B loop range. Only meaningful when `repeatMode == .abLoop`. `nil` when no range has been set.
    public var abRepeat: ABRepeatRange?
    /// Per-score master output volume. `1.0` (`defaultMasterVolume`) is unity — the mix plays at the score's authored
    /// level. Boosts up to `maxMasterVolume` (300%) raise the whole mix past per-staff CC7's ceiling; the engine
    /// brick-wall-limits the result so a boost doesn't clip. Clamped to `[minMasterVolume, maxMasterVolume]` when set.
    /// `nil` = the user never chose, so it resolves to the default via `effectiveMasterVolume`.
    public var masterVolume: Double?
    /// Per-score transposition offset in semitones. `0` (`defaultTransposeSemitones`) means no transposition. Clamped
    /// to `[-7, +7]` (a diminished fifth / tritone either way) when set, matching the engine's supported range.
    /// `nil` = the user never chose, so it resolves to the default via `effectiveTransposeSemitones`.
    public var transposeSemitones: Int?
    /// Per-score A4 reference override in Hz. `nil` = inherit the global default. Clamped to
    /// `[A4Reference.minHz, A4Reference.maxHz]` when set.
    public var a4ReferenceHz: Double?
    /// Whether the Reader has already reconciled this row with the score's authored `<Part><show>` hidden staves. Rows
    /// created before that feature (and non-notation formats, which have no authored visibility) carry `false`; on open
    /// the Reader seeds/back-fills the authored-hidden staves once, sets this `true`, and thereafter returns the user's
    /// value untouched so staves the user revealed are never re-hidden. Defaults to `false`.
    public var hasSeededAuthoredVisibility: Bool

    public init(
        id: ReaderPreferencesID = ReaderPreferencesID(),
        scoreItemID: ScoreItemID,
        staffSize: Double? = nil,
        hiddenStaves: Set<StaffAddress>,
        staffProgramOverrides: [StaffAddress: Int] = [:],
        staffVolumeOverrides: [StaffAddress: Double] = [:],
        staffClefOverrides: [StaffAddress: String] = [:],
        tempoMultiplier: Double? = nil,
        honorLayoutBreaks: Bool? = nil,
        repeatMode: RepeatMode = .off,
        abRepeat: ABRepeatRange? = nil,
        masterVolume: Double? = nil,
        transposeSemitones: Int? = nil,
        a4ReferenceHz: Double? = nil,
        hasSeededAuthoredVisibility: Bool = false,
    ) {
        self.id = id
        self.scoreItemID = scoreItemID
        self.staffSize = staffSize.map { min(max($0, Self.minStaffSize), Self.maxStaffSize) }
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
        self.masterVolume = masterVolume.map {
            min(max($0, Self.minMasterVolume), Self.maxMasterVolume)
        }
        self.transposeSemitones = transposeSemitones.map { min(max($0, -7), 7) }
        self.a4ReferenceHz = a4ReferenceHz.map(A4Reference.clamp)
        self.hasSeededAuthoredVisibility = hasSeededAuthoredVisibility
    }

    /// The value to use for a field the user may never have set: the stored value when there is one, the default
    /// otherwise. Reading through these is what keeps `nil` from having to be materialized at the use site.
    public var effectiveHonorLayoutBreaks: Bool {
        honorLayoutBreaks ?? Self.defaultHonorLayoutBreaks
    }

    public var effectiveMasterVolume: Double {
        masterVolume ?? Self.defaultMasterVolume
    }

    public var effectiveTransposeSemitones: Int {
        transposeSemitones ?? Self.defaultTransposeSemitones
    }

    /// Staff size resolved against the caller's default, because the default is device-class-dependent and so can't
    /// live on the model.
    public func effectiveStaffSize(default defaultValue: Double) -> Double {
        staffSize ?? defaultValue
    }

    /// Whether any setting addressed by staff index is set. These are exactly the settings that stop meaning what the
    /// user chose if the staves are renumbered — which is what re-reading a PDF can do.
    public var hasStaffBoundOverrides: Bool {
        !hiddenStaves.isEmpty
            || !staffProgramOverrides.isEmpty
            || !staffVolumeOverrides.isEmpty
            || !staffClefOverrides.isEmpty
            || (transposeSemitones ?? 0) != 0
    }

    /// A copy with every staff-index-addressed setting reset. Sound-only settings (tempo, A4, master volume, repeat)
    /// and `staffSize` survive — they don't reference staves by index. `transposeSemitones` goes back to `nil`
    /// (untouched) rather than an explicit `0`, since the user's choice no longer applies to the new staff numbering.
    /// `hasSeededAuthoredVisibility` goes back to `false` so the next open re-seeds the new parse's authored hidden
    /// staves.
    public func clearingStaffBoundOverrides() -> ReaderPreferences {
        var copy = self
        copy.hiddenStaves = []
        copy.staffProgramOverrides = [:]
        copy.staffVolumeOverrides = [:]
        copy.staffClefOverrides = [:]
        copy.transposeSemitones = nil
        copy.hasSeededAuthoredVisibility = false
        return copy
    }

    private enum CodingKeys: String, CodingKey {
        case id, scoreItemID, staffSize, hiddenStaves, staffProgramOverrides
        case staffVolumeOverrides, tempoMultiplier, honorLayoutBreaks
        case repeatMode, abRepeat, masterVolume, a4ReferenceHz
        case staffClefOverrides
        case transposeSemitones
        case hasSeededAuthoredVisibility
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(ReaderPreferencesID.self, forKey: .id)
        let scoreItemID = try c.decode(ScoreItemID.self, forKey: .scoreItemID)
        let staffSize = try c.decodeIfPresent(Double.self, forKey: .staffSize)
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
        let honorBreaks = try c.decodeIfPresent(Bool.self, forKey: .honorLayoutBreaks)
        let mode = try c.decodeIfPresent(RepeatMode.self, forKey: .repeatMode) ?? .off
        let ab = try c.decodeIfPresent(ABRepeatRange.self, forKey: .abRepeat)
        let master = try c.decodeIfPresent(Double.self, forKey: .masterVolume)
        let transpose = try c.decodeIfPresent(Int.self, forKey: .transposeSemitones)
        let a4 = try c.decodeIfPresent(Double.self, forKey: .a4ReferenceHz)
        let hasSeeded = try c.decodeIfPresent(
            Bool.self, forKey: .hasSeededAuthoredVisibility,
        ) ?? false
        self.init(
            id: id, scoreItemID: scoreItemID, staffSize: staffSize,
            hiddenStaves: hiddenStaves, staffProgramOverrides: programOverrides,
            staffVolumeOverrides: volumeOverrides,
            staffClefOverrides: clefOverrides,
            tempoMultiplier: tempo,
            honorLayoutBreaks: honorBreaks, repeatMode: mode, abRepeat: ab,
            masterVolume: master,
            transposeSemitones: transpose,
            a4ReferenceHz: a4,
            hasSeededAuthoredVisibility: hasSeeded,
        )
    }
}
