import Domain
import Foundation
import SheetMusic
import SheetMusicMSCX

/// Live `ScoreShareService` backed by `swift-sheet-music`. Companion to `LiveScoreFileGateway` in the same module.
public struct LiveScoreShareService: ScoreShareService {
    private let scoresDirectory: URL
    private let shareTempDirectory: URL
    private let gateway: any ScoreFileGateway
    private let audioExporter: any ScoreAudioExporter
    private let pdfRenderer: any ScorePDFRenderer
    private let annotatedPDFRenderer: any AnnotatedPDFRendering
    private let annotationStore: any AnnotationStore

    public init(
        scoresDirectory: URL,
        shareTempDirectory: URL,
        gateway: any ScoreFileGateway,
        audioExporter: any ScoreAudioExporter,
        pdfRenderer: any ScorePDFRenderer,
        annotatedPDFRenderer: any AnnotatedPDFRendering,
        annotationStore: any AnnotationStore,
    ) {
        self.scoresDirectory = scoresDirectory
        self.shareTempDirectory = shareTempDirectory
        self.gateway = gateway
        self.audioExporter = audioExporter
        self.pdfRenderer = pdfRenderer
        self.annotatedPDFRenderer = annotatedPDFRenderer
        self.annotationStore = annotationStore
    }

    public func availableFormats(for item: ScoreItem) async -> [ScoreShareFormatOption] {
        let original = await detectOriginalFormat(for: item)
        let plain = ScoreShareFormat.allOrdered.map {
            ScoreShareFormatOption(format: $0, isOriginal: $0 == original)
        }
        let drawings = await drawings(for: item)
        // An annotated export is never the source's own bytes, so these rows are never flagged `isOriginal`.
        let annotated = AnnotatedExportAvailability.formats(
            hasMusicalInk: drawings.contains {
                if case .musical = $0.kind {
                    true
                } else {
                    false
                }
            },
            hasPageInk: drawings.contains {
                if case .page = $0.kind {
                    true
                } else {
                    false
                }
            },
            hasOriginalPDF: item.originalPDFFileName != nil,
            isEngravable: item.pdfOriginState != .unconverted,
        ).map { ScoreShareFormatOption(format: $0) }
        return plain + annotated
    }

    /// The item's stored drawing anchors, or none. A store failure degrades to "no ink" — the plain formats still
    /// work, which is better than failing the whole menu over an annotation read.
    private func drawings(for item: ScoreItem) async -> [DrawingAnchor] {
        guard let layer = try? await annotationStore.annotationLayer(forScoreItem: item.id) else { return [] }
        return layer.drawings
    }

    public func prepareShare(
        item: ScoreItem,
        format: ScoreShareFormat,
    ) async throws -> URL {
        if format == .annotatedOriginalPDF {
            return try await writeAnnotatedOriginalPDF(item: item)
        }

        let sourceURL = scoresDirectory.appending(path: item.localFileName)
        let (score, _) = try await gateway.loadScore(fileURL: sourceURL)

        if format == .annotatedPDF {
            return try await writeAnnotatedEngravedPDF(score: score, item: item)
        }

        let title = ScoreExportNaming.sanitize(title: item.title)
        if ScoreShareFormat.matching(for: score.source) == format {
            return try copyOriginalBytes(sourceURL: sourceURL, sanitizedTitle: title)
        }

        switch format {
        case .museScoreV4:
            return try writeMSCZ(score: score, sanitizedTitle: title, target: .v4)
        case .museScoreV3:
            return try writeMSCZ(score: score, sanitizedTitle: title, target: .v3)
        case .pdf:
            return try await writePDF(score: score, item: item, sanitizedTitle: title)
        case .midi:
            return try writeMIDI(score: score, sanitizedTitle: title)
        case .audioM4A:
            return try await writeM4A(score: score, sanitizedTitle: title)
        case .annotatedPDF, .annotatedOriginalPDF:
            // Both are handled above, before the score loads — the original-PDF path needs no parse and this switch
            // never sees them.
            throw DomainError.scoreWriteFailed(reason: "annotated formats are handled above")
        }
    }

    // MARK: - Annotated export

    private func writeAnnotatedEngravedPDF(score: Score, item: ScoreItem) async throws -> URL {
        let drawings = try await requireDrawings(for: item)
        let data = try await annotatedPDFRenderer.renderAnnotatedEngravedPDF(
            score: score, title: item.title, drawings: drawings,
        )
        return try write(data, item: item, format: .annotatedPDF)
    }

    private func writeAnnotatedOriginalPDF(item: ScoreItem) async throws -> URL {
        guard let name = item.originalPDFFileName else {
            // `item.localFileName` is not what's missing — it's the score file, which exists. There is no original
            // PDF at all (never was, or `sourcePDFFileName` was cleared), so there's no on-disk name to report;
            // name the thing that's actually absent.
            throw DomainError.scoreFileNotFound(name: "\(item.title) (original PDF)")
        }
        let url = scoresDirectory.appending(path: name)
        guard let basePDF = try? Data(contentsOf: url) else {
            throw DomainError.scoreFileNotFound(name: name)
        }
        let drawings = try await requireDrawings(for: item)
        let data = try await annotatedPDFRenderer.renderAnnotatedOriginalPDF(
            basePDF: basePDF, drawings: drawings,
        )
        return try write(data, item: item, format: .annotatedOriginalPDF)
    }

    /// An annotated export with no ink is a bug, not a valid share — the row is only offered when the item has some,
    /// so reaching here means the layer went away between the menu opening and the tap.
    ///
    /// Reads the store directly rather than through `drawings(for:)`: that helper's `try?` degrade-to-no-ink is
    /// right for `availableFormats`, where a store hiccup should just leave the menu unflagged, but on the export
    /// path it would make a genuine read failure indistinguishable from a legitimately empty layer — both would
    /// throw the same "no annotations" error. Letting the store's own error propagate here keeps the two apart.
    private func requireDrawings(for item: ScoreItem) async throws -> [DrawingAnchor] {
        let drawings = try await annotationStore.annotationLayer(forScoreItem: item.id)?.drawings ?? []
        guard !drawings.isEmpty else {
            throw DomainError.scoreWriteFailed(reason: "annotated export: the item has no annotations")
        }
        return drawings
    }

    private func write(_ data: Data, item: ScoreItem, format: ScoreShareFormat) throws -> URL {
        let destination = shareTempDirectory.appending(
            path: ScoreExportNaming.fileName(title: item.title, format: format),
        )
        try? FileManager.default.removeItem(at: destination)
        do {
            try data.write(to: destination)
        } catch {
            throw DomainError.scoreWriteFailed(reason: "\(error)")
        }
        return destination
    }

    // MARK: - Source-based mapping

    /// Loads the item via the gateway just to read `Score.source` and map it to the matching share format. Errors map
    /// to `nil` so a transient parse failure simply leaves the menu unflagged instead of breaking it.
    private func detectOriginalFormat(for item: ScoreItem) async -> ScoreShareFormat? {
        let url = scoresDirectory.appending(path: item.localFileName)
        guard let result = try? await gateway.loadScore(fileURL: url) else { return nil }
        return ScoreShareFormat.matching(for: result.0.source)
    }

    // MARK: - Original-bytes copy

    /// Copy the source file as-is into the share temp directory, preserving its extension. Used when the picked format
    /// matches the item's source byte-for-byte.
    private func copyOriginalBytes(
        sourceURL: URL,
        sanitizedTitle: String,
    ) throws -> URL {
        let ext = sourceURL.pathExtension
        let destination = shareTempDirectory.appending(path: "\(sanitizedTitle).\(ext)")
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destination)
        } catch {
            throw DomainError.scoreFileNotFound(name: sourceURL.lastPathComponent)
        }
        return destination
    }

    // MARK: - Encoder paths

    private func writeMIDI(
        score: Score,
        sanitizedTitle: String,
    ) throws -> URL {
        let midiData: Data
        do {
            midiData = try SheetMusic.exportMIDI(score: score)
        } catch {
            throw DomainError.scoreWriteFailed(reason: "\(error)")
        }
        let destination = shareTempDirectory.appending(path: "\(sanitizedTitle).mid")
        try? FileManager.default.removeItem(at: destination)
        do {
            try midiData.write(to: destination)
        } catch {
            throw DomainError.scoreWriteFailed(reason: "\(error)")
        }
        return destination
    }

    private func writePDF(
        score: Score,
        item: ScoreItem,
        sanitizedTitle: String,
    ) async throws -> URL {
        let pdfData = try await pdfRenderer.renderPDF(score: score, title: item.title)
        let destination = shareTempDirectory.appending(path: "\(sanitizedTitle).pdf")
        try? FileManager.default.removeItem(at: destination)
        do {
            try pdfData.write(to: destination)
        } catch {
            throw DomainError.scoreWriteFailed(reason: "\(error)")
        }
        return destination
    }

    private func writeMSCZ(
        score: Score,
        sanitizedTitle: String,
        target: MSCXVersion,
    ) throws -> URL {
        let destination = shareTempDirectory.appending(path: "\(sanitizedTitle).mscz")
        try? FileManager.default.removeItem(at: destination)
        do {
            try MSCZWriter.write(
                score: score,
                options: MSCXEncoderOptions(targetVersion: target),
                to: destination,
            )
        } catch {
            throw DomainError.scoreWriteFailed(reason: "\(error)")
        }
        return destination
    }

    private func writeM4A(
        score: Score,
        sanitizedTitle: String,
    ) async throws -> URL {
        let destination = shareTempDirectory.appending(path: "\(sanitizedTitle).m4a")
        try? FileManager.default.removeItem(at: destination)
        try await audioExporter.exportM4A(score: score, to: destination)
        return destination
    }
}
