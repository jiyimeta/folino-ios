import Wirelet

/// Persistence projection of a score, marshaled across the JNI boundary to the
/// Kotlin/Room backend as `data class ScoreRecordWire(...)`. Distinct from
/// `ScoreRowWire` (the display projection) because it carries the persisted
/// fields the backend stores verbatim: the on-disk file name and the
/// soft-delete timestamp.
///
/// `deletedAt` mirrors the iOS `ScoreItem.deletedAt: Date?`: it is the Unix
/// time (`Date.timeIntervalSince1970`) at which the row was soft-deleted, or
/// `0` when the row is live. (`0` — 1970 — is never a real deletion instant,
/// so it is a safe "not deleted" sentinel and avoids marshaling an Optional.)
@WireFormat
public struct ScoreRecordWire: Equatable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String
    public var composer: String
    public var localFileName: String // "<id>.mscz" — built in Swift, iOS naming convention
    public var deletedAt: Double // 0 == live; >0 == soft-deleted at that Unix time
    public var isFavorite: Bool // mirrors iOS ScoreItem.isFavorite

    public init(
        id: String,
        title: String,
        subtitle: String,
        composer: String,
        localFileName: String,
        deletedAt: Double,
        isFavorite: Bool = false,
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.composer = composer
        self.localFileName = localFileName
        self.deletedAt = deletedAt
        self.isFavorite = isFavorite
    }
}
