import Domain
import Foundation
import SheetMusic

/// Reads read-only metadata (source format + credit metaTags) from a library item's on-disk file by parsing it on
/// demand via the score gateway — the same lazy parse the share service uses. Used by the Library edit sheet to show
/// the source and to pre-fill credit fields that have never been edited.
public struct LiveScoreMetadataReader: ScoreMetadataReading {
    private let gateway: any ScoreFileGateway
    private let scoresDirectory: URL

    public init(gateway: any ScoreFileGateway, scoresDirectory: URL) {
        self.gateway = gateway
        self.scoresDirectory = scoresDirectory
    }

    public func readMetadata(for item: ScoreItem) async throws -> ScoreFileMetadata {
        let url = scoresDirectory.appending(path: item.localFileName)
        let (score, _) = try await gateway.loadScore(fileURL: url)
        return ScoreFileMetadata(score: score)
    }
}
