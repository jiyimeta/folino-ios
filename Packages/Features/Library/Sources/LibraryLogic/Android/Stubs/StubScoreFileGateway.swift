#if os(Android)
import Domain
import Foundation

/// Stub file gateway for the Android JNI pilot. The pilot only exercises list rendering and search;
/// none of the gateway methods are invoked by LibraryStore during that flow. Methods that cannot
/// return a meaningful value on Android (loadScore, saveScore) throw DomainError.unsupportedFormat.
public struct StubScoreFileGateway: ScoreFileGateway {
    public init() {}

    public func detectFormat(fileName: String) -> ScoreFormat? {
        ScoreFormat.detect(filename: fileName)
    }

    public func loadFileMetadata(fileURL: URL) throws -> ScoreFileSummary {
        ScoreFileSummary(
            title: fileURL.deletingPathExtension().lastPathComponent,
            composer: nil,
            instrumentationSummary: "Unknown",
            lengthBeats: 0,
            defaultTempoBpm: 120,
            primaryKey: nil,
        )
    }

    public func loadScore(fileURL: URL) throws -> (score: Score, summary: ScoreFileSummary) {
        throw DomainError.unsupportedFormat("StubScoreFileGateway: loadScore not available on Android")
    }

    public func saveScore(_ score: Score, fileURL: URL, format: ScoreFormat) throws {
        throw DomainError.unsupportedFormat("StubScoreFileGateway: saveScore not available on Android")
    }
}
#endif
