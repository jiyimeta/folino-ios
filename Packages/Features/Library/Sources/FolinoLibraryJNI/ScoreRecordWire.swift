import Wirelet

/// Persistence projection of a score, marshaled across the JNI boundary to the
/// Kotlin/Room backend as `data class ScoreRecordWire(...)`. Distinct from
/// `ScoreRowWire` (the display projection) because it carries the persisted
/// fields the backend stores verbatim: the on-disk file name, the soft-delete
/// timestamp, and the SHA-256 content hash.
///
/// `deletedAt` mirrors the iOS `ScoreItem.deletedAt: Date?`: it is the Unix
/// time (`Date.timeIntervalSince1970`) at which the row was soft-deleted, or
/// `0` when the row is live. (`0` — 1970 — is never a real deletion instant,
/// so it is a safe "not deleted" sentinel and avoids marshaling an Optional.)
///
/// `contentHash` is the lowercase SHA-256 hex digest of the score's source bytes at
/// import time, used for duplicate detection on re-import. `""` when unknown
/// (e.g. legacy rows that pre-date hash recording).
@WireFormat
public struct ScoreRecordWire: Equatable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String
    public var composer: String
    public var localFileName: String // "<id>.mscz" — built in Swift, iOS naming convention
    public var contentHash: String // SHA-256 hex of source bytes; "" for legacy rows
    public var deletedAt: Double // 0 == live; >0 == soft-deleted at that Unix time
    public var isFavorite: Bool // mirrors iOS ScoreItem.isFavorite

    public init(
        id: String,
        title: String,
        subtitle: String,
        composer: String,
        localFileName: String,
        contentHash: String = "",
        deletedAt: Double,
        isFavorite: Bool = false,
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.composer = composer
        self.localFileName = localFileName
        self.contentHash = contentHash
        self.deletedAt = deletedAt
        self.isFavorite = isFavorite
    }
}
