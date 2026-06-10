import Wirelet

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
