import Domain
import Foundation
@testable import Reader
import Testing

/// Shared scaffolding for the PDF-origin reader tests: a temp scores directory holding a real `sample.pdf`, a
/// `ScoreItem` pointing at it, and a conversion closure whose behavior and call count the test controls.
@MainActor
final class PDFReaderTestRig {
    enum Conversion {
        /// Writes a stand-in score file and reports facts for it.
        case succeeds
        /// Reads nothing out of the PDF.
        case fails
        /// Fails the first call, succeeds afterwards — the retry story for an unreadable PDF.
        case failsThenSucceeds
    }

    let scoresDirectory: URL
    private(set) var item: ScoreItem
    let repository: FakeScoreLibraryRepository
    private(set) var conversionCallCount = 0

    private let conversion: Conversion

    /// - Parameters:
    ///   - converted: build the rig with the PDF already read into notation (the state after import).
    ///   - edited: mark the notation as edited since the conversion wrote it.
    init(conversion: Conversion = .succeeds, converted: Bool = false, edited: Bool = false) throws {
        self.conversion = conversion
        let source = try #require(Bundle.module.url(forResource: "sample", withExtension: "pdf"))
        let id = ScoreItemID()
        scoresDirectory = FileManager.default.temporaryDirectory
            .appending(path: "PDFReaderTestRig-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scoresDirectory, withIntermediateDirectories: true)

        let pdfName = "\(id.rawValue.uuidString).pdf"
        try FileManager.default.copyItem(at: source, to: scoresDirectory.appending(path: pdfName))
        let msczName = "\(id.rawValue.uuidString).mscz"
        if converted {
            try Data("mscz".utf8).write(to: scoresDirectory.appending(path: msczName))
        }

        item = ScoreItem(
            id: id,
            title: "Sample",
            composer: nil,
            instrumentationSummary: nil,
            localFileName: converted ? msczName : pdfName,
            contentHash: converted && edited ? "edited-hash" : "seed-hash",
            sizeBytes: 0,
            lengthBeats: 0,
            defaultTempoBpm: 0,
            primaryKey: nil,
            addedAt: Date(timeIntervalSince1970: 0),
            lastOpenedAt: nil,
            tagIDs: [],
            isFavorite: false,
            sourcePDFFileName: pdfName,
            sourcePDFContentHash: "pdf-hash",
            pdfDerivedContentHash: converted ? "seed-hash" : nil,
        )
        repository = FakeScoreLibraryRepository()
        repository.scoreItems = [item]
    }

    /// A plain-score item that never came from a PDF.
    static func scoreItem() throws -> PDFReaderTestRig {
        let rig = try PDFReaderTestRig(converted: true)
        rig.item = ScoreItem(
            id: rig.item.id,
            title: "Plain",
            composer: nil,
            instrumentationSummary: nil,
            localFileName: rig.item.localFileName,
            contentHash: "hash",
            sizeBytes: 0,
            lengthBeats: 0,
            defaultTempoBpm: 0,
            primaryKey: nil,
            addedAt: Date(timeIntervalSince1970: 0),
            lastOpenedAt: nil,
            tagIDs: [],
            isFavorite: false,
        )
        rig.repository.scoreItems = [rig.item]
        return rig
    }

    func makeViewModel() -> ReaderViewModel {
        ReaderViewModel(
            scoreItem: item,
            repository: repository,
            gateway: FakeScoreFileGateway(),
            scoresDirectory: scoresDirectory,
            pdfConversion: makeConversion(),
        )
    }

    private func makeConversion() -> PDFScoreConversion {
        { [weak self] _, destination in
            guard let self else { return nil }
            let call = await MainActor.run { () -> Int in
                self.conversionCallCount += 1
                return self.conversionCallCount
            }
            let shouldSucceed = switch conversion {
            case .succeeds: true
            case .fails: false
            case .failsThenSucceeds: call > 1
            }
            guard shouldSucceed else { return nil }
            try? Data("mscz".utf8).write(to: destination)
            return PDFConversionFacts(
                fileName: destination.lastPathComponent,
                contentHash: "converted-\(call)",
                sizeBytes: 4,
                summary: ScoreFileSummary(
                    title: "Parsed",
                    composer: "Parsed Composer",
                    instrumentationSummary: "Piano",
                    lengthBeats: 32,
                    defaultTempoBpm: 100,
                    primaryKey: nil,
                ),
            )
        }
    }
}
