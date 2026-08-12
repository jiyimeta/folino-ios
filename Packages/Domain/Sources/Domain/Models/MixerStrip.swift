import Foundation

/// One controllable sound in the mixer: a (part × distinct instrument) pair, which is the unit the audio engine
/// addresses. NOT a staff — a grand staff is two staves playing one instrument through one channel, and a part
/// that changes instrument mid-score is one staff driving several.
///
/// `instrumentOrdinal` indexes the part's deduped instruments in first-appearance order, so it is stable for a
/// given score and matches the engine's channel set one-to-one.
public struct MixerStripID: Hashable, Sendable, Codable {
    public let partIndex: Int
    public let instrumentOrdinal: Int

    public init(partIndex: Int, instrumentOrdinal: Int) {
        self.partIndex = partIndex
        self.instrumentOrdinal = instrumentOrdinal
    }

    /// Encoded as a two-element unkeyed array `[partIndex, instrumentOrdinal]`, matching `StaffAddress`. The
    /// persisted override columns hold `[key0, key1, value]` rows, so keeping the shape is what lets a stored
    /// staff-keyed override migrate by dropping rows rather than by being rewritten.
    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        partIndex = try container.decode(Int.self)
        instrumentOrdinal = try container.decode(Int.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(partIndex)
        try container.encode(instrumentOrdinal)
    }
}

/// A strip as the engine reports it, for the mixer to draw. Everything here is the SCORE's authored value, read
/// before any user override is applied — the Infrastructure adapter snapshots it between preparing the engine and
/// seeding it, because the engine's own list is mutated by that seeding.
public struct MixerStrip: Hashable, Sendable, Identifiable {
    public let id: MixerStripID
    /// The part this strip belongs to — a group's title when one is drawn.
    public let partName: String
    /// The instrument driving it, unqualified by the part — a row's label under such a title.
    public let instrumentName: String
    /// The score's authored level, `0 ... 1`. The slider's reset target.
    public let defaultVolume: Double
    /// The score's authored program. On a drum strip this is the KIT.
    public let defaultProgram: Int
    /// Whether the program is a drum kit, so the picker offers that catalog rather than the melodic one.
    public let isDrums: Bool

    public init(
        id: MixerStripID,
        partName: String,
        instrumentName: String,
        defaultVolume: Double,
        defaultProgram: Int,
        isDrums: Bool,
    ) {
        self.id = id
        self.partName = partName
        self.instrumentName = instrumentName
        self.defaultVolume = min(max(defaultVolume, 0), 1)
        self.defaultProgram = min(max(defaultProgram, 0), 127)
        self.isDrums = isDrums
    }
}
