import Wirelet

/// Scalar projection of `ReaderPreferences` for Compose, mirroring `SoundfontStateWire`. `honorLayoutBreaks` is
/// folded in here because the observable emitter does not project a bare `Bool` stored property on the bridge.
/// Sentinels (Wirelet has no `nil`): `tempoMultiplier == 0` ⇒ no override; `a4ReferenceHz == 0` ⇒ inherit global.
///
/// `revision` is a monotonically increasing change token bumped on every `republish()`. The per-staff collections
/// (hidden / clef / program / volume) live outside this struct, reachable only through `@WireletExpose` getters,
/// so a mutation that touches only a collection leaves every scalar field unchanged. Without `revision` the
/// rebuilt wire would be `Equatable`-equal to the prior value, and the Kotlin `MutableStateFlow` would dedup it —
/// the Compose consumer's `remember(state) { vm.hiddenStaves() }` would then never re-read the getter and the
/// change wouldn't surface until the screen is recreated. `revision` forces a distinct value so the state ticks
/// on every mutation, honoring the "re-read getters whenever state ticks" contract on the Kotlin side.
@WireFormat
public struct ReaderPreferencesStateWire: Equatable, Sendable {
    public var staffSize: Double
    public var honorLayoutBreaks: Bool
    public var masterVolume: Double
    public var tempoMultiplier: Double // 0 => no override
    public var a4ReferenceHz: Double // 0 => inherit global
    public var transposeSemitones: Int32
    public var revision: Int32 // change token; bumped on every republish so per-staff mutations are not deduped

    public init(
        staffSize: Double,
        honorLayoutBreaks: Bool,
        masterVolume: Double,
        tempoMultiplier: Double,
        a4ReferenceHz: Double,
        transposeSemitones: Int32,
        revision: Int32 = 0,
    ) {
        self.staffSize = staffSize
        self.honorLayoutBreaks = honorLayoutBreaks
        self.masterVolume = masterVolume
        self.tempoMultiplier = tempoMultiplier
        self.a4ReferenceHz = a4ReferenceHz
        self.transposeSemitones = transposeSemitones
        self.revision = revision
    }
}

/// A per-strip GM program override projected to Compose. The two integers are Domain `MixerStripID` —
/// `partIndex` plus `instrumentOrdinal`, the part's deduped instruments in order of first appearance — and NOT a
/// `StaffAddress`: a grand staff is two staves and one strip, an instrument-change part one staff and several.
/// `program` is the 0…127 GM program, or the bank-128 kit number on a drum strip.
@WireFormat
public struct ProgramOverrideWire: Equatable, Sendable {
    public var partIndex: Int32
    public var instrumentOrdinal: Int32
    public var program: Int32

    public init(partIndex: Int32, instrumentOrdinal: Int32, program: Int32) {
        self.partIndex = partIndex
        self.instrumentOrdinal = instrumentOrdinal
        self.program = program
    }
}

/// A per-strip volume override (0…1) projected to Compose, addressed like `ProgramOverrideWire`.
@WireFormat
public struct VolumeOverrideWire: Equatable, Sendable {
    public var partIndex: Int32
    public var instrumentOrdinal: Int32
    public var volume: Double

    public init(partIndex: Int32, instrumentOrdinal: Int32, volume: Double) {
        self.partIndex = partIndex
        self.instrumentOrdinal = instrumentOrdinal
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
