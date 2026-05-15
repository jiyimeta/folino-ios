import Domain
import Foundation

public struct DrainResult: Sendable {
    public let imported: [ScoreItemID]
    public let skipped: [Skip]
    public let openAfter: ScoreItemID?
    public let createdPlaylistID: PlaylistID?
    public let targetPlaylistID: PlaylistID?
    public let targetPlaylistName: String?

    public init(
        imported: [ScoreItemID],
        skipped: [Skip],
        openAfter: ScoreItemID?,
        createdPlaylistID: PlaylistID?,
        targetPlaylistID: PlaylistID?,
        targetPlaylistName: String?,
    ) {
        self.imported = imported
        self.skipped = skipped
        self.openAfter = openAfter
        self.createdPlaylistID = createdPlaylistID
        self.targetPlaylistID = targetPlaylistID
        self.targetPlaylistName = targetPlaylistName
    }

    public static let empty = DrainResult(
        imported: [],
        skipped: [],
        openAfter: nil,
        createdPlaylistID: nil,
        targetPlaylistID: nil,
        targetPlaylistName: nil,
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
