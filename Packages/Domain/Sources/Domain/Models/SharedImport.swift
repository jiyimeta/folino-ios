import Foundation

/// One staged file handed to the coordinator: an absolute path to readable bytes plus the user-facing original name.
public struct SharedImportFile: Sendable, Equatable {
    public let path: String
    public let originalName: String
    public init(path: String, originalName: String) {
        self.path = path
        self.originalName = originalName
    }
}

/// Why a file was not imported. `id`/`title` strings are raw (UUID string, display title) so the type is
/// platform-neutral.
public enum SharedImportSkipReason: Sendable, Equatable {
    case missingFile
    case parseFailed
    case persistenceFailed
    case duplicate(existingID: String, existingTitle: String)
}

public struct SharedImportSkip: Sendable, Equatable {
    public let originalName: String
    public let reason: SharedImportSkipReason
    public init(originalName: String, reason: SharedImportSkipReason) {
        self.originalName = originalName
        self.reason = reason
    }
}

/// Per-file outcome an importer reports back to the coordinator.
public enum SharedImportFileResult: Sendable, Equatable {
    case imported(id: String)
    case duplicate(existingID: String, existingTitle: String)
    case skipped(SharedImportSkipReason)
}

/// Platform import: hashing, duplicate detection, parsing, persistence all happen behind this. `isMultiFile` lets the
/// implementation route a duplicate confirmation differently for batch vs single shares (iOS resolver).
public protocol SharedImportFileImporting: Sendable {
    func importFile(_ file: SharedImportFile, isMultiFile: Bool) async -> SharedImportFileResult
}

/// Platform playlist operations the coordinator needs. All ids are UUID strings.
public protocol SharedImportPlaylistTargeting: Sendable {
    func playlistExists(id: String) -> Bool
    /// Create a playlist; return its new id, or `nil` if creation failed.
    func createPlaylist(name: String) -> String?
    func append(scoreIDs: [String], toPlaylistID id: String)
}

/// Aggregated outcome (platform-neutral, UUID strings). Each platform maps this to its own richer result if needed.
public struct SharedImportResult: Sendable, Equatable {
    public var importedIDs: [String]
    public var skipped: [SharedImportSkip]
    public var openAfterID: String?
    public var createdPlaylistID: String?
    public var targetPlaylistID: String?
    public var playlistCreateFailureName: String?

    public init(
        importedIDs: [String] = [],
        skipped: [SharedImportSkip] = [],
        openAfterID: String? = nil,
        createdPlaylistID: String? = nil,
        targetPlaylistID: String? = nil,
        playlistCreateFailureName: String? = nil,
    ) {
        self.importedIDs = importedIDs
        self.skipped = skipped
        self.openAfterID = openAfterID
        self.createdPlaylistID = createdPlaylistID
        self.targetPlaylistID = targetPlaylistID
        self.playlistCreateFailureName = playlistCreateFailureName
    }
}
