import Foundation

/// Strongly-typed identifier for a `ScoreItem`. Two identifiers of the same kind
/// can be equated; two identifiers of different kinds are different types and
/// will not compile when compared.
public struct ScoreItemID: Hashable, Sendable, Codable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct TagID: Hashable, Sendable, Codable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct PlaylistID: Hashable, Sendable, Codable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct AnnotationID: Hashable, Sendable, Codable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct AnnotationLayerID: Hashable, Sendable, Codable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct PlaybackPreferencesID: Hashable, Sendable, Codable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct ReaderPreferencesID: Hashable, Sendable, Codable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

/// Identity of a SoundFont 2 patch. Two patches with the same
/// `(bank, program, isDrums)` are interchangeable — the cache records
/// use this as the primary key. `isDrums` distinguishes a melodic
/// preset (e.g. `000_000.sf2` Acoustic Grand Piano) from a percussion
/// preset that shares the same on-paper `(bank, program)` but is
/// loaded at the percussion `bankMSB`.
public struct SoundfontPatchKey: Hashable, Sendable, Codable {
    public let bank: Int
    public let program: Int
    public let isDrums: Bool

    public init(bank: Int, program: Int, isDrums: Bool = false) {
        self.bank = bank
        self.program = program
        self.isDrums = isDrums
    }
}
