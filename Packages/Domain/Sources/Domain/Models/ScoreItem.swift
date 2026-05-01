import Foundation

/// A persisted entry in Folino's library. The actual score bytes live on disk
/// at `AppPaths.scoresDirectory/localFileName` (the resolution to absolute URL
/// happens in Infrastructure, not Domain).
public struct ScoreItem: Hashable, Sendable, Codable, Identifiable {
    public let id: ScoreItemID
    public var title: String
    public var composer: String?
    public var instrumentationSummary: String?
    public var format: ScoreFormat
    /// Filename relative to the scores directory. Convention: `<id>.<canonical-extension>`.
    public var localFileName: String
    public var sizeBytes: Int64
    public var lengthBeats: Int
    public var defaultTempoBpm: Int
    public var primaryKey: String?
    public let addedAt: Date
    public var lastOpenedAt: Date?
    public var tagIDs: Set<TagID>
    public var isFavorite: Bool

    public init(
        id: ScoreItemID = ScoreItemID(),
        title: String,
        composer: String?,
        instrumentationSummary: String?,
        format: ScoreFormat,
        localFileName: String,
        sizeBytes: Int64,
        lengthBeats: Int,
        defaultTempoBpm: Int,
        primaryKey: String?,
        addedAt: Date,
        lastOpenedAt: Date?,
        tagIDs: Set<TagID>,
        isFavorite: Bool
    ) {
        self.id = id
        self.title = title
        self.composer = composer
        self.instrumentationSummary = instrumentationSummary
        self.format = format
        self.localFileName = localFileName
        self.sizeBytes = sizeBytes
        self.lengthBeats = lengthBeats
        self.defaultTempoBpm = defaultTempoBpm
        self.primaryKey = primaryKey
        self.addedAt = addedAt
        self.lastOpenedAt = lastOpenedAt
        self.tagIDs = tagIDs
        self.isFavorite = isFavorite
    }
}
