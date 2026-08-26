#if DEBUG
import Domain
import Foundation
import Observation
import SwiftUI

/// Minimal in-memory doubles so the preview is self-contained (no App composition root needed). None of these are
/// exercised by rendering the sheet — `NewScoreSheet` only calls into `viewModel.createScore(from:)` when Create is
/// tapped, and into `instrumentation(of:)` when a source score is picked, neither of which a static preview drives —
/// so every method is a stub.
@MainActor
@Observable
private final class PreviewScoreLibraryRepository: ScoreLibraryRepository {
    var scoreItems: [ScoreItem] = [
        PreviewScoreLibraryRepository.item(title: "Trio in D", summary: "Violin, Viola, Cello"),
        PreviewScoreLibraryRepository.item(title: "Ballad", summary: "Voice, Piano"),
    ]
    var deletedScoreItems: [ScoreItem] = []
    var tags: [Tag] = []
    var playlists: [Playlist] = []

    private static func item(title: String, summary: String) -> ScoreItem {
        ScoreItem(
            title: title, composer: nil, instrumentationSummary: summary,
            localFileName: "\(title).mscx", contentHash: title,
            sizeBytes: 0, lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: Date(timeIntervalSince1970: 1_700_000_000), lastOpenedAt: nil,
            tagIDs: [], isFavorite: false,
        )
    }

    func refresh() {}
    func saveScoreItem(_: ScoreItem) {}
    func deleteScoreItem(id _: ScoreItemID) {}
    func softDeleteScoreItem(id _: ScoreItemID) {}
    func restoreScoreItem(id _: ScoreItemID) {}
    func permanentlyDeleteScoreItem(id _: ScoreItemID) {}
    func pruneScoreItemsDeleted(before _: Date) {}
    func saveTag(_: Tag) {}
    func deleteTag(id _: TagID) {}
    func savePlaylist(_: Playlist) {}
    func deletePlaylist(id _: PlaylistID) {}
    func scoreItems(matchingContentHash _: String) -> [ScoreItem] {
        []
    }

    func loadReaderPreferences(for _: ScoreItemID) -> ReaderPreferences? {
        nil
    }

    func saveReaderPreferences(_: ReaderPreferences) {}
    func allReaderPreferences() -> [ReaderPreferences] {
        []
    }
}

private struct PreviewScoreOriginalStore: ScoreOriginalStore {
    func captureOriginalIfNeeded(for item: ScoreItem) -> ScoreItem {
        item
    }

    func revertToOriginal(_ item: ScoreItem, restoringScoreInfo _: Bool) -> ScoreItem {
        item
    }

    func discardOriginal(for item: ScoreItem) -> ScoreItem {
        item
    }
}

private struct PreviewScoreFileImporter: ScoreFileImporter {
    func prepareImport(sourceURL _: URL) throws -> ImportPlan {
        throw DomainError.unsupportedFormat("preview")
    }

    func commitImport(_: ImportPlan, decision _: ImportDecision) throws -> ScoreItem {
        throw DomainError.unsupportedFormat("preview")
    }
}

private struct PreviewScoreFileGateway: ScoreFileGateway {
    func detectFormat(fileName _: String) -> ScoreFormat? {
        nil
    }

    func loadFileMetadata(fileURL _: URL) throws -> ScoreFileSummary {
        throw DomainError.unsupportedFormat("preview")
    }

    func loadScore(fileURL _: URL) throws -> (score: Score, summary: ScoreFileSummary) {
        throw DomainError.unsupportedFormat("preview")
    }

    func saveScore(_: Score, fileURL _: URL, format: ScoreFormat) throws {
        throw DomainError.unsupportedFormat(format.canonicalExtension)
    }
}

private struct PreviewScoreShareService: ScoreShareService {
    func availableFormats(for _: ScoreItem) -> [ScoreShareFormatOption] {
        []
    }

    func prepareShare(item _: ScoreItem, format: ScoreShareFormat) throws -> URL {
        throw DomainError.unsupportedFormat(format.canonicalExtension)
    }
}

private struct PreviewScoreMetadataReading: ScoreMetadataReading {
    func readMetadata(for _: ScoreItem) throws -> ScoreFileMetadata {
        throw DomainError.unsupportedFormat("preview")
    }
}

private struct PreviewScoreFileCreator: ScoreFileCreator {
    func createScore(_: Score) throws -> ScoreItem {
        throw DomainError.unsupportedFormat("preview")
    }
}

@MainActor
private func previewViewModel() -> LibraryViewModel {
    LibraryViewModel(
        repository: PreviewScoreLibraryRepository(),
        originalStore: PreviewScoreOriginalStore(),
        importer: PreviewScoreFileImporter(),
        gateway: PreviewScoreFileGateway(),
        shareService: PreviewScoreShareService(),
        metadataReader: PreviewScoreMetadataReading(),
        creator: PreviewScoreFileCreator(),
        scoresDirectory: URL(filePath: "/tmp"),
    )
}

// A fresh form: the solo-piano seed, one grand-staff row.
#Preview("New score") {
    NewScoreSheet(viewModel: previewViewModel())
}

// The instrumentation section carrying an ensemble, so the list, its duplicate numbering ("Violin 1" /
// "Violin 2") and the staff-count annotation are all visible at once.
#Preview("Ensemble applied") {
    var form = NewScoreForm()
    form.title = "Quartet No. 1"
    form.composer = "K. Ito"
    form.applyTemplate(ScoreCreationTemplate.all.first { $0.id == "string-quartet" } ?? ScoreCreationTemplate.all[0])
    form.addInstrument(ScoreInstrument.instrument(id: "piano") ?? ScoreInstrument.all[0])
    return NewScoreSheet(viewModel: previewViewModel(), form: form)
}
#endif
