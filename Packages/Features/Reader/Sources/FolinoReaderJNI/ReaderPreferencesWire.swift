import Wirelet

/// A per-staff GM program override projected to Compose. `partIndex`/`staffIndexInPart`
/// mirror Domain `StaffAddress`; `program` is the 0…127 GM program.
@WireFormat
public struct ProgramOverrideWire: Equatable, Sendable {
    public var partIndex: Int
    public var staffIndexInPart: Int
    public var program: Int

    public init(partIndex: Int, staffIndexInPart: Int, program: Int) {
        self.partIndex = partIndex
        self.staffIndexInPart = staffIndexInPart
        self.program = program
    }
}

/// A per-staff volume override (0…1) projected to Compose.
@WireFormat
public struct VolumeOverrideWire: Equatable, Sendable {
    public var partIndex: Int
    public var staffIndexInPart: Int
    public var volume: Double

    public init(partIndex: Int, staffIndexInPart: Int, volume: Double) {
        self.partIndex = partIndex
        self.staffIndexInPart = staffIndexInPart
        self.volume = volume
    }
}

/// A hidden-staff entry projected to Compose (part/staff address).
@WireFormat
public struct HiddenStaffEntryWire: Equatable, Sendable {
    public var partIndex: Int
    public var staffIndexInPart: Int

    public init(partIndex: Int, staffIndexInPart: Int) {
        self.partIndex = partIndex
        self.staffIndexInPart = staffIndexInPart
    }
}

/// A clef override entry projected to Compose (part/staff address + NotatedClef.rawType).
@WireFormat
public struct ClefOverrideEntryWire: Equatable, Sendable {
    public var partIndex: Int
    public var staffIndexInPart: Int
    public var rawType: String

    public init(partIndex: Int, staffIndexInPart: Int, rawType: String) {
        self.partIndex = partIndex
        self.staffIndexInPart = staffIndexInPart
        self.rawType = rawType
    }
}
