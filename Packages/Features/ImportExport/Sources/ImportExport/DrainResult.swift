import Domain
import Foundation

public struct DrainResult: Sendable {
    public let imported: [ScoreItemID]
    public let skipped: [Skip]
    /// The score to open in the Reader once the drain completes, or `nil` when the user chose not to open or nothing
    /// was imported. Carries the full `ScoreItem` (not just its ID) so the App layer can navigate without looking it up
    /// in the repository's asynchronously-observed snapshot, which may not yet reflect the freshly-imported item.
    public let openAfter: ScoreItem?
    public let createdPlaylistID: PlaylistID?
    public let targetPlaylistID: PlaylistID?
    public let targetPlaylistName: String?
    /// When non-nil, the coordinator attempted to create a new playlist with this name but the persistence call threw.
    /// The staged token is preserved on disk so the user can retry on the next drain. The banner reads `Couldn't create
    /// playlist "<name>"`.
    public let playlistCreateFailure: String?

    public init(
        imported: [ScoreItemID],
        skipped: [Skip],
        openAfter: ScoreItem?,
        createdPlaylistID: PlaylistID?,
        targetPlaylistID: PlaylistID?,
        targetPlaylistName: String?,
        playlistCreateFailure: String? = nil,
    ) {
        self.imported = imported
        self.skipped = skipped
        self.openAfter = openAfter
        self.createdPlaylistID = createdPlaylistID
        self.targetPlaylistID = targetPlaylistID
        self.targetPlaylistName = targetPlaylistName
        self.playlistCreateFailure = playlistCreateFailure
    }

    public static let empty = DrainResult(
        imported: [],
        skipped: [],
        openAfter: nil,
        createdPlaylistID: nil,
        targetPlaylistID: nil,
        targetPlaylistName: nil,
        playlistCreateFailure: nil,
    )
}

public struct Skip: Sendable {
    public let originalName: String
    public let reason: SkipReason

    public init(originalName: String, reason: SkipReason) {
        self.originalName = originalName
        self.reason = reason
    }
}

public enum SkipReason: Sendable {
    case unsupportedFormat
    case unreadable(any Error)
    case parseFailed(any Error)
    case persistenceFailed(any Error)
    case duplicate(existingID: ScoreItemID, existingTitle: String)
}
