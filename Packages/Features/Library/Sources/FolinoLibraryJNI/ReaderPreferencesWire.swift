import Wirelet

/// Scalar projection of `ReaderPreferences` for Compose, mirroring `SoundfontStateWire`. `honorLayoutBreaks` is
/// folded in here because the observable emitter does not project a bare `Bool` stored property on the bridge.
/// Sentinels (Wirelet has no `nil`): `tempoMultiplier == 0` ⇒ no override; `a4ReferenceHz == 0` ⇒ inherit global.
@WireFormat
public struct ReaderPreferencesStateWire: Equatable, Sendable {
    public var staffSize: Double
    public var honorLayoutBreaks: Bool
    public var masterVolume: Double
    public var tempoMultiplier: Double // 0 => no override
    public var a4ReferenceHz: Double // 0 => inherit global
    public var transposeSemitones: Int32

    public init(
        staffSize: Double,
        honorLayoutBreaks: Bool,
        masterVolume: Double,
        tempoMultiplier: Double,
        a4ReferenceHz: Double,
        transposeSemitones: Int32,
    ) {
        self.staffSize = staffSize
        self.honorLayoutBreaks = honorLayoutBreaks
        self.masterVolume = masterVolume
        self.tempoMultiplier = tempoMultiplier
        self.a4ReferenceHz = a4ReferenceHz
        self.transposeSemitones = transposeSemitones
    }
}

/// A per-staff GM program override projected to Compose. `partIndex`/`staffIndexInPart`
/// mirror Domain `StaffAddress`; `program` is the 0…127 GM program.
@WireFormat
public struct ProgramOverrideWire: Equatable, Sendable {
    public var partIndex: Int32
    public var staffIndexInPart: Int32
    public var program: Int32

    public init(partIndex: Int32, staffIndexInPart: Int32, program: Int32) {
        self.partIndex = partIndex
        self.staffIndexInPart = staffIndexInPart
        self.program = program
    }
}

/// A per-staff volume override (0…1) projected to Compose.
@WireFormat
public struct VolumeOverrideWire: Equatable, Sendable {
    public var partIndex: Int32
    public var staffIndexInPart: Int32
    public var volume: Double

    public init(partIndex: Int32, staffIndexInPart: Int32, volume: Double) {
        self.partIndex = partIndex
        self.staffIndexInPart = staffIndexInPart
        self.volume = volume
    }
}

/// A hidden-staff entry projected to Compose (part/staff address).
@WireFormat
public struct HiddenStaffEntryWire: Equatable, Sendable {
    public var partIndex: Int32
    public var staffIndexInPart: Int32

    public init(partIndex: Int32, staffIndexInPart: Int32) {
        self.partIndex = partIndex
        self.staffIndexInPart = staffIndexInPart
    }
}

/// A clef override entry projected to Compose (part/staff address + NotatedClef.rawType).
@WireFormat
public struct ClefOverrideEntryWire: Equatable, Sendable {
    public var partIndex: Int32
    public var staffIndexInPart: Int32
    public var rawType: String

    public init(partIndex: Int32, staffIndexInPart: Int32, rawType: String) {
        self.partIndex = partIndex
        self.staffIndexInPart = staffIndexInPart
        self.rawType = rawType
    }
}
