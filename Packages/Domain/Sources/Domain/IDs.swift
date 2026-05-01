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

/// Identity of a SoundFont 2 patch. Two patches with the same (bank, program)
/// are interchangeable — the cache records use this as the primary key.
public struct SoundfontPatchKey: Hashable, Sendable, Codable {
    public let bank: Int
    public let program: Int

    public init(bank: Int, program: Int) {
        self.bank = bank
        self.program = program
    }
}
