import Wirelet

/// Display projection of a score row, marshaled across the JNI boundary
/// as a Kotlin `data class ScoreRowWire(id, title, subtitle, composer, isFavorite, isPdf, localFileName)`.
/// Fields mirror the iOS Library row (title + subtitle on the primary line,
/// composer on the secondary line; `isFavorite` drives the row's star; `isPdf`
/// drives the "PDF" label, matching `ScoreRow.swift`'s `PDFBadge`). `localFileName` is the
/// record's real on-disk file name (Room `local_file_name`) — the App layer threads it down to
/// the Reader (via the nav route / retarget path) so the Reader is TOLD which file to open
/// rather than looking it up itself; the Reader module has no dependency on the Library module.
@WireFormat
public struct ScoreRowWire: Equatable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String
    public var composer: String
    public var isFavorite: Bool
    public var isPdf: Bool
    public var localFileName: String

    public init(
        id: String,
        title: String,
        subtitle: String,
        composer: String,
        isFavorite: Bool = false,
        isPdf: Bool = false,
        localFileName: String = "",
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.composer = composer
        self.isFavorite = isFavorite
        self.isPdf = isPdf
        self.localFileName = localFileName
    }
}
