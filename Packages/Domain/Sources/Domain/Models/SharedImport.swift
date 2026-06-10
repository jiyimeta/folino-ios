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
    func playlistExists(id: String) async -> Bool
    /// Create a playlist; return its new id, or `nil` if creation failed.
    func createPlaylist(name: String) async -> String?
    func append(scoreIDs: [String], toPlaylistID id: String) async
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

/// Platform-agnostic share-import orchestration: resolve the playlist target, import each file, append imported ids to
/// the target, and pick the open-after id. All platform I/O lives behind the two injected protocols. Mirrors the iOS
/// `IncomingShareCoordinator` per-token sequence, including "new-playlist creation failed ⇒ import nothing".
public struct SharedImportCoordinator: Sendable {
    private let importer: any SharedImportFileImporting
    private let target: any SharedImportPlaylistTargeting

    public init(importer: any SharedImportFileImporting, target: any SharedImportPlaylistTargeting) {
        self.importer = importer
        self.target = target
    }

    public func run(files: [SharedImportFile], choice: PlaylistChoice, openAfter: Bool) async -> SharedImportResult {
        var result = SharedImportResult()

        // 1. Resolve playlist target.
        var targetPlaylistID: String?
        switch choice {
        case .libraryOnly:
            break
        case let .existing(id):
            let raw = id.rawValue.uuidString
            // A playlist deleted between pick and import silently falls back to library-only (iOS
            // IncomingShareCoordinator.resolvePlaylist parity: an unresolved existing id becomes .none).
            if await target.playlistExists(id: raw) { targetPlaylistID = raw }
        case let .createNew(name):
            // A blank/whitespace-only name falls back to library-only (iOS parity: trimmed-empty newPlaylistName
            // resolves to .none). The Android share UI also disables Save while the name field is blank.
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                if let newID = await target.createPlaylist(name: trimmed) {
                    targetPlaylistID = newID
                    result.createdPlaylistID = newID
                } else {
                    // iOS parity: nothing is imported; the banner reports the failed name.
                    result.playlistCreateFailureName = trimmed
                    return result
                }
            }
        }

        // 2. Import each file.
        let isMultiFile = files.count > 1
        var lastOpen: String?
        for file in files {
            switch await importer.importFile(file, isMultiFile: isMultiFile) {
            case let .imported(id):
                result.importedIDs.append(id)
                lastOpen = id
            case let .duplicate(existingID, existingTitle):
                result.skipped.append(.init(
                    originalName: file.originalName,
                    reason: .duplicate(existingID: existingID, existingTitle: existingTitle),
                ))
                lastOpen = existingID
            case let .skipped(reason):
                result.skipped.append(.init(originalName: file.originalName, reason: reason))
            }
        }

        // 3. Append to playlist (imported-only; duplicates stay in the library and are not re-added to the playlist).
        if let pid = targetPlaylistID {
            if !result.importedIDs.isEmpty { await target.append(scoreIDs: result.importedIDs, toPlaylistID: pid) }
            result.targetPlaylistID = pid
        }

        // 4. Open-after.
        if openAfter { result.openAfterID = lastOpen }
        return result
    }
}
