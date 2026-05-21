#if os(Android)
import Domain
import Foundation

/// Stub share service for the Android JNI pilot. Returns a static stub URL; availableFormats
/// returns the full set with no "original" flagged since no real Score is parsed.
public struct StubScoreShareService: ScoreShareService {
    public init() {}

    public func availableFormats(for item: ScoreItem) -> [ScoreShareFormatOption] {
        [
            ScoreShareFormatOption(format: .museScoreV4),
            ScoreShareFormatOption(format: .museScoreV3),
            ScoreShareFormatOption(format: .midi),
        ]
    }

    public func prepareShare(item: ScoreItem, format: ScoreShareFormat) throws -> URL {
        // swiftlint:disable:next force_unwrapping
        URL(string: "stub://share/\(item.id.rawValue.uuidString)")!
    }
}
#endif
