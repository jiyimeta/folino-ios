import Wirelet

/// Display projection of a score row, marshaled across the JNI boundary
/// as a Kotlin `data class ScoreRowWire(id, title, subtitle, composer)`.
/// Fields mirror the iOS Library row (title + subtitle on the primary line,
/// composer on the secondary line).
@WireFormat
public struct ScoreRowWire: Equatable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String
    public var composer: String
    public var isFavorite: Bool

    public init(id: String, title: String, subtitle: String, composer: String, isFavorite: Bool = false) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.composer = composer
        self.isFavorite = isFavorite
    }
}
