import Wirelet

/// Display projection of a score row, marshaled across the JNI boundary
/// as a Kotlin `data class ScoreRowWire(id, title, composer)`.
@WireFormat
public struct ScoreRowWire: Equatable, Sendable {
    public var id: String
    public var title: String
    public var composer: String

    public init(id: String, title: String, composer: String) {
        self.id = id
        self.title = title
        self.composer = composer
    }
}
