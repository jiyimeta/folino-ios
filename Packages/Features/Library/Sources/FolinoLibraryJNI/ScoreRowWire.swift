import Wirelet

/// Display projection of a score row, marshaled across the JNI boundary
/// as a Kotlin `data class ScoreRowWire(id, title, subtitle, composer, isFavorite, isPdf)`.
/// Fields mirror the iOS Library row (title + subtitle on the primary line,
/// composer on the secondary line; `isFavorite` drives the row's star; `isPdf`
/// drives the "PDF" label, matching `ScoreRow.swift`'s `PDFBadge`).
@WireFormat
public struct ScoreRowWire: Equatable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String
    public var composer: String
    public var isFavorite: Bool
    public var isPdf: Bool

    public init(
        id: String,
        title: String,
        subtitle: String,
        composer: String,
        isFavorite: Bool = false,
        isPdf: Bool = false,
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.composer = composer
        self.isFavorite = isFavorite
        self.isPdf = isPdf
    }
}
