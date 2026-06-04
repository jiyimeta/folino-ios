import Wirelet

/// One row in the Android export sheet, marshaled across the JNI boundary as a
/// Kotlin `data class ScoreExportFormatWire(format, isOriginal)`. `format` is a
/// stable token (`museScoreV4` | `museScoreV3` | `pdf` | `midi` | `audioM4A`)
/// the Compose layer maps to a label; `isOriginal == true` flags the row that
/// re-emits the score's source bytes verbatim. Mirrors iOS `ScoreShareFormatOption`.
@WireFormat
public struct ScoreExportFormatWire: Equatable, Sendable {
    public var format: String
    public var isOriginal: Bool

    public init(format: String, isOriginal: Bool) {
        self.format = format
        self.isOriginal = isOriginal
    }
}
