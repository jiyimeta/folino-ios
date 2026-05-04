import SheetMusicCore

// `StaffAddress` is `Hashable & Sendable & Comparable` upstream but not
// `Codable`. Domain needs Codable so `ReaderPreferences` (which holds a
// `Set<StaffAddress>`) can round-trip through JSON / GRDB blobs.
//
// Encoded as a two-element unkeyed array `[partIndex, staffIndexInPart]`
// — compact and stable across versions.
extension SheetMusicCore.StaffAddress: @retroactive Codable {
    public init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        let partIndex = try container.decode(Int.self)
        let staffIndexInPart = try container.decode(Int.self)
        self.init(partIndex: partIndex, staffIndexInPart: staffIndexInPart)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(partIndex)
        try container.encode(staffIndexInPart)
    }
}
