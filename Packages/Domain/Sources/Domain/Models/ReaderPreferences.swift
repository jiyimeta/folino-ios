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

    /// Defaults an untouched (`nil`) field resolves to. Staff size and the break policy have NO static default here —
    /// theirs are device-class-dependent (`ReaderDeviceDefaults` on iOS, `ReaderDeviceDefaults.kt` on Android), so
    /// resolution takes them as arguments instead.
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
    /// Score-derived ground truth of the staves the score itself authored hidden (`<Part><show>false`), refreshed on
    /// every open. It is provenance, not user intent — subtracting it from `hiddenStaves` isolates what the user
    /// actually did: `hiddenStaves.subtracting(authoredHiddenStaves)` is what the user hid on their own, and
    /// `authoredHiddenStaves.subtracting(hiddenStaves)` is what the user revealed against the score's wishes.
    public var authoredHiddenStaves: Set<StaffAddress>
    /// User-chosen GM program (0…127) per mixer strip that overrides whatever the score declares. Absent entries fall
    /// back to the score's instrument channel program. Bank stays at 0 — the picker only swaps melodic programs
    /// (matches `swift-sheet-music`'s `ProgramMenu`).
    public var stripProgramOverrides: [MixerStripID: Int]
    /// User-chosen volume `[0, 1]` per mixer strip that overrides the score's mscx CC7. Absent entries fall back to
    /// the score's `InstrumentChannel.volume` (mapped from `0…127` to `0…1`), then to `1.0` if the score has no
    /// matching part. Matches the override-overlay shape of `stripProgramOverrides`.
    public var stripVolumeOverrides: [MixerStripID: Double]
    /// User-chosen display-only clef per staff that overrides the score's authored opening clef. Values are
    /// `NotatedClef.rawType` strings (e.g. `"G"`, `"G8vb"`, `"F8va"`, `"C3"`). Stored as `String` to avoid pulling
    /// `SheetMusicLayout` into Domain — the Reader feature converts via `NotatedClef(rawType:)` at the use site.
    /// Unknown rawTypes are dropped by the initializer.
    public var staffClefOverrides: [StaffAddress: String]
    /// Per-score playback rate override. `nil` means "no override" — the engine plays at the score's native tempo. Set
    /// values are clamped to `[minTempoMultiplier, maxTempoMultiplier]`. The Reader's view model normalizes a saved
    /// value of exactly 1.0 back to `nil` so the override doesn't outlive the user's intent.
    public var tempoMultiplier: Double?
    /// When `true`, the layout engine honors authored `<LayoutBreak>line` / `<LayoutBreak>page` markup, so
    /// the engraver's chosen system / page boundaries are reproduced. When `false`, the engine ignores both forms and
    /// wraps measures purely on the available view width — useful when the score was authored for a different page
    /// size. `nil` = the user never chose, so it resolves to the caller's device-class default via
    /// `effectiveHonorLayoutBreaks(default:)`.
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
    /// the Reader seeds/back-fills the authored-hidden staves once and sets this `true`. Thereafter `hiddenStaves` is
    /// the user's alone — a staff they revealed is never re-hidden — but `authoredHiddenStaves` keeps being refreshed
    /// on open whenever it disagrees with the score, which is what makes the provenance self-healing across re-reads
    /// and staff renumbering (see `reconcilingAuthoredHidden`). Defaults to `false`.
    public var hasSeededAuthoredVisibility: Bool

    public init(
        id: ReaderPreferencesID = ReaderPreferencesID(),
        scoreItemID: ScoreItemID,
        staffSize: Double? = nil,
        hiddenStaves: Set<StaffAddress>,
        authoredHiddenStaves: Set<StaffAddress> = [],
        stripProgramOverrides: [MixerStripID: Int] = [:],
        stripVolumeOverrides: [MixerStripID: Double] = [:],
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
        self.authoredHiddenStaves = authoredHiddenStaves
        self.stripProgramOverrides = stripProgramOverrides.mapValues { min(max($0, 0), 127) }
        self.stripVolumeOverrides = stripVolumeOverrides.mapValues { min(max($0, 0), 1) }
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

    /// Break policy resolved against the caller's default, because the default is device-class-dependent (a phone
    /// ignores authored breaks and wraps to the viewport; a tablet reproduces the engraver's boundaries) and so can't
    /// live on the model.
    public func effectiveHonorLayoutBreaks(default defaultValue: Bool) -> Bool {
        honorLayoutBreaks ?? defaultValue
    }

    /// Whether any setting addressed by an index the score supplies, which a re-parse can renumber, is set. These are
    /// exactly the settings that stop meaning what the user chose if that renumbering happens — which is what
    /// re-reading a PDF can do.
    public var hasScoreBoundOverrides: Bool {
        !hiddenStaves.isEmpty
            || !stripProgramOverrides.isEmpty
            || !stripVolumeOverrides.isEmpty
            || !staffClefOverrides.isEmpty
            || (transposeSemitones ?? 0) != 0
    }

    /// A copy with every setting addressed by an index the score supplies, which a re-parse can renumber, reset.
    /// Sound-only settings (tempo, A4, master volume, repeat) and `staffSize` survive — they don't reference such an
    /// index. `transposeSemitones` goes back to `nil` (untouched) rather than an explicit `0`, since the user's
    /// choice no longer applies to the new numbering. `hasSeededAuthoredVisibility` goes back to `false` so the next
    /// open re-seeds the new parse's authored hidden staves, and `authoredHiddenStaves` is emptied with it: keeping
    /// the old parse's provenance next to an emptied `hiddenStaves` would read as "the user revealed all of these"
    /// until the score is opened again.
    public func clearingScoreBoundOverrides() -> ReaderPreferences {
        var copy = self
        copy.hiddenStaves = []
        copy.authoredHiddenStaves = []
        copy.stripProgramOverrides = [:]
        copy.stripVolumeOverrides = [:]
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
        case authoredHiddenStaves
        case schemaVersion
    }

    /// Version stamped into every encoded payload. `1` is implicit: blobs written before this key existed simply
    /// don't carry it, which is exactly what `init(from:)` uses to recognize legacy data. `3` is when
    /// `staffProgramOverrides` / `staffVolumeOverrides` (the JSON keys, unchanged) switched from addressing a staff
    /// to addressing a mixer strip — a blob at `2` or earlier decodes those rows as staff-keyed and gets collapsed.
    static let codableSchemaVersion = 3

    /// What the pre-`schemaVersion` code stored for a user who had never chosen anything — staff size was seeded to
    /// the then-default 14, and the other three were written eagerly at their defaults. Frozen on purpose: a
    /// migration must keep describing the data as it was written, even if the live defaults later move.
    private enum LegacyStoredDefaults {
        static let staffSize: Double = 14
        static let honorLayoutBreaks = true
        static let masterVolume: Double = 1
        static let transposeSemitones = 0
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.codableSchemaVersion, forKey: .schemaVersion)
        try c.encode(id, forKey: .id)
        try c.encode(scoreItemID, forKey: .scoreItemID)
        try c.encodeIfPresent(staffSize, forKey: .staffSize)
        try c.encode(hiddenStaves, forKey: .hiddenStaves)
        try c.encode(authoredHiddenStaves, forKey: .authoredHiddenStaves)
        try c.encode(stripProgramOverrides, forKey: .staffProgramOverrides)
        try c.encode(stripVolumeOverrides, forKey: .staffVolumeOverrides)
        try c.encode(staffClefOverrides, forKey: .staffClefOverrides)
        try c.encodeIfPresent(tempoMultiplier, forKey: .tempoMultiplier)
        try c.encodeIfPresent(honorLayoutBreaks, forKey: .honorLayoutBreaks)
        try c.encode(repeatMode, forKey: .repeatMode)
        try c.encodeIfPresent(abRepeat, forKey: .abRepeat)
        try c.encodeIfPresent(masterVolume, forKey: .masterVolume)
        try c.encodeIfPresent(transposeSemitones, forKey: .transposeSemitones)
        try c.encodeIfPresent(a4ReferenceHz, forKey: .a4ReferenceHz)
        try c.encode(hasSeededAuthoredVisibility, forKey: .hasSeededAuthoredVisibility)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // A blob with no `schemaVersion` predates the "untouched is `nil`" model: back then every scalar was written
        // eagerly, so a stored default is indistinguishable from an untouched one and is reclassified as untouched
        // below. This is the Android counterpart of the iOS v16 migration — the JSON-blob store has no migration
        // runner, so the version marker lives in the payload.
        //
        // The marker is what makes the conversion one-time IN EFFECT: the next `encode(to:)` stamps
        // `codableSchemaVersion`, after which present values are authoritative. Without it the normalization would
        // re-run on every read and permanently collapse a deliberately re-chosen default back to "untouched".
        // iOS persistence never takes this path (GRDB records only), so the blast radius is the Android blob.
        let schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion)
        let isLegacy = schemaVersion == nil
        let id = try c.decode(ReaderPreferencesID.self, forKey: .id)
        let scoreItemID = try c.decode(ScoreItemID.self, forKey: .scoreItemID)
        let rawStaffSize = try c.decodeIfPresent(Double.self, forKey: .staffSize)
        let staffSize = (isLegacy && rawStaffSize == LegacyStoredDefaults.staffSize) ? nil : rawStaffSize
        let hiddenStaves = try c.decode(Set<StaffAddress>.self, forKey: .hiddenStaves)
        // Legacy blobs have no provenance to read, so all of their hides are attributed to the score — the same
        // conservative seed the iOS v16 migration makes (`authored_hidden_staves` starts as a copy of
        // `hidden_staff_ids`). Under-reporting user intent is the safe direction, and the next open self-heals it via
        // `reconcilingAuthoredHidden`. A v2 blob always writes the key, so an absent one there genuinely means
        // "nothing authored hidden" and must NOT be back-seeded.
        let authoredHidden = try c.decodeIfPresent(
            Set<StaffAddress>.self, forKey: .authoredHiddenStaves,
        ) ?? (isLegacy ? hiddenStaves : [])
        var programOverrides = try c.decodeIfPresent(
            [MixerStripID: Int].self, forKey: .staffProgramOverrides,
        ) ?? [:]
        var volumeOverrides = try c.decodeIfPresent(
            [MixerStripID: Double].self, forKey: .staffVolumeOverrides,
        ) ?? [:]
        // A blob at schema 2 or earlier keyed these by STAFF. A staff and a strip both encode as two integers,
        // so the rows decode without complaint and mean the wrong thing: `[0,1]` was "part 0's second staff",
        // which under strips is "part 0's second instrument" — a different sound. Collapse to the part's first
        // entry, which is what the SQL migration does to the same rows.
        let isPreStrip = (schemaVersion ?? 0) < 3
        if isPreStrip {
            programOverrides = programOverrides.filter { $0.key.instrumentOrdinal == 0 }
            volumeOverrides = volumeOverrides.filter { $0.key.instrumentOrdinal == 0 }
        }
        let clefOverrides = try c.decodeIfPresent(
            [StaffAddress: String].self, forKey: .staffClefOverrides,
        ) ?? [:]
        let tempo = try c.decodeIfPresent(Double.self, forKey: .tempoMultiplier)
        let rawHonorBreaks = try c.decodeIfPresent(Bool.self, forKey: .honorLayoutBreaks)
        let honorBreaks = (isLegacy && rawHonorBreaks == LegacyStoredDefaults.honorLayoutBreaks)
            ? nil : rawHonorBreaks
        let mode = try c.decodeIfPresent(RepeatMode.self, forKey: .repeatMode) ?? .off
        let ab = try c.decodeIfPresent(ABRepeatRange.self, forKey: .abRepeat)
        let rawMaster = try c.decodeIfPresent(Double.self, forKey: .masterVolume)
        let master = (isLegacy && rawMaster == LegacyStoredDefaults.masterVolume) ? nil : rawMaster
        let rawTranspose = try c.decodeIfPresent(Int.self, forKey: .transposeSemitones)
        let transpose = (isLegacy && rawTranspose == LegacyStoredDefaults.transposeSemitones)
            ? nil : rawTranspose
        let a4 = try c.decodeIfPresent(Double.self, forKey: .a4ReferenceHz)
        let hasSeeded = try c.decodeIfPresent(
            Bool.self, forKey: .hasSeededAuthoredVisibility,
        ) ?? false
        self.init(
            id: id, scoreItemID: scoreItemID, staffSize: staffSize,
            hiddenStaves: hiddenStaves, authoredHiddenStaves: authoredHidden,
            stripProgramOverrides: programOverrides,
            stripVolumeOverrides: volumeOverrides,
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
