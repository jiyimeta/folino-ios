import Domain
import Foundation
import UtilityCore

public final class LiveScoreFileCreator: ScoreFileCreator, Sendable {
    private let gateway: any ScoreFileGateway
    // `ScoreLibraryRepository` is `@MainActor`-isolated, which guarantees single-actor access. Swift 6's type system
    // doesn't (yet) infer Sendable from the actor annotation alone, so we assert it here. Mirrors
    // `LiveScoreFileImporter`.
    private nonisolated(unsafe) let repository: any ScoreLibraryRepository
    private let scoresDirectory: URL

    public init(
        gateway: any ScoreFileGateway,
        repository: any ScoreLibraryRepository,
        scoresDirectory: URL,
    ) {
        self.gateway = gateway
        self.repository = repository
        self.scoresDirectory = scoresDirectory
    }

    public func createScore(_ score: Score) async throws -> ScoreItem {
        let id = ScoreItemID()
        let fileName = "\(id.rawValue.uuidString).mscx"
        let fileURL = scoresDirectory.appending(path: fileName)
        try await gateway.saveScore(score, fileURL: fileURL, format: .mscx)

        do {
            let facts = try FileFacts.hashAndSize(of: fileURL)
            let summary = ScoreFileSummary(score: score)
            // `ScoreFileSummary(score:)` always leaves `title` `nil` — the importer path derives title from the
            // source file name instead (a freshly-built score has none). Scratch creation has no file name, so the
            // title comes straight from the score's own `workTitle` metaTag, which is exactly where `Score.blank`
            // wrote it. Same convention swift-sheet-music itself uses (`JNISymbols.swift`, `ScoreEntry.swift`).
            let item = ScoreItem(
                id: id,
                title: score.metaTags["workTitle"] ?? "",
                subtitle: summary.subtitle,
                composer: summary.composer,
                arranger: summary.arranger,
                lyricist: summary.lyricist,
                copyright: summary.copyright,
                instrumentationSummary: summary.instrumentationSummary,
                localFileName: fileName,
                contentHash: facts.contentHash,
                sizeBytes: facts.sizeBytes,
                lengthBeats: summary.lengthBeats,
                defaultTempoBpm: summary.defaultTempoBpm,
                primaryKey: summary.primaryKey,
                addedAt: Date(),
                lastOpenedAt: nil,
                tagIDs: [],
                isFavorite: false,
                museScoreMajorVersion: summary.museScoreMajorVersion,
                sourcePDFFileName: nil,
                sourcePDFContentHash: nil,
                pdfDerivedContentHash: nil,
                pdfConversionFailed: false,
            )
            try await repository.saveScoreItem(item)
            return item
        } catch {
            // Same rule as the importer: never leave a file no row points at.
            try? FileManager.default.removeItem(at: fileURL)
            throw error
        }
    }
}
