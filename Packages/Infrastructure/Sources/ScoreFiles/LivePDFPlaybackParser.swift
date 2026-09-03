import Domain
import Foundation
import OSLog
import SheetMusicPDF
#if canImport(SheetMusicOMRModel)
import SheetMusicOMRModel
#endif

/// `PDFPlaybackParser` backed by swift-sheet-music's public PDF OMR importer. Reconstructs a playable
/// `Score` plus the on-PDF geometry side-car, and collects the importer's best-effort diagnostics.
///
/// The heavy synchronous OMR pipeline runs on a detached background task so it never blocks the
/// MainActor caller (the Reader awaits the result).
///
/// Pages with no vector content (a scan, a photo, a "print to PDF" of a raster) go through the bundled Core ML
/// detector when it loads; the decision is per page inside the importer, so a typeset title page followed by
/// scanned music needs no choice here. If the model fails to load, the parse still runs vector-only, exactly as
/// it did before the detector existed, and the failure is logged once.
public struct LivePDFPlaybackParser: PDFPlaybackParser {
    public init() {}

    public func parse(pdfURL: URL) async throws -> PDFPlaybackParseResult {
        try await Task.detached(priority: .userInitiated) {
            try Self.parseSynchronously(pdfURL: pdfURL, classifier: Self.omrClassifier)
        }.value
    }

    private static let logger = Logger(subsystem: "com.KeyNumber.Folino", category: "PDFImport")

    /// The bundled OMR model, loaded once per process on first use. The first parse pays the load, inside its own
    /// detached task, so it never lands on the main actor. A load failure is sticky on purpose: the bundled resources
    /// cannot appear later, and retrying on every import would only repeat the log line.
    private static let omrClassifier: (any OMRTileClassifier)? = {
        #if canImport(SheetMusicOMRModel)
        do {
            return try CoreMLTileClassifier()
        } catch {
            logger.error("OMR model failed to load; scanned PDFs will import empty: \(error, privacy: .public)")
            return nil
        }
        #else
        return nil
        #endif
    }()

    private static func parseSynchronously(
        pdfURL: URL,
        classifier: (any OMRTileClassifier)?,
    ) throws -> PDFPlaybackParseResult {
        let collector = DiagnosticsCollector()
        var options = PDFImportOptions()
        options.omrTileClassifier = classifier
        options.diagnostics = { diagnostic in
            collector.append(diagnostic)
            let text = "\(diagnostic.location): \(diagnostic.message)"
            switch diagnostic.severity {
            case .warning: logger.warning("PDF import warning — \(text, privacy: .public)")
            case .info: logger.info("PDF import info — \(text, privacy: .public)")
            @unknown default: logger.info("PDF import — \(text, privacy: .public)")
            }
        }
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let (score, geometry) = try PDFImporter.parseWithGeometry(pdfURL: pdfURL, options: options)
            let elapsed = clock.now - start
            logger.info(
                """
                PDF import of \(pdfURL.lastPathComponent, privacy: .private) took \(elapsed, privacy: .public): \
                \(score.playableElementCount) playable elements, \(collector.snapshot().count) diagnostics, \
                OMR \(classifier == nil ? "unavailable" : "available", privacy: .public)
                """,
            )
            return PDFPlaybackParseResult(
                score: score,
                geometry: SheetMusicPDFPlaybackGeometry(geometry),
                diagnostics: collector.snapshot(),
            )
        } catch {
            throw DomainError.scoreParseFailed(reason: "\(error)")
        }
    }
}

/// Thread-safe sink for the importer's `@Sendable` diagnostics callback. The importer invokes it
/// synchronously during the (single-threaded) parse, but the lock keeps it sound regardless.
private final class DiagnosticsCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [PDFParseDiagnostic] = []

    func append(_ diagnostic: PDFImportDiagnostic) {
        let severity: PDFParseDiagnostic.Severity = switch diagnostic.severity {
        case .warning: .warning
        case .info: .info
        @unknown default: .info
        }
        let mapped = PDFParseDiagnostic(
            severity: severity,
            location: diagnostic.location,
            message: diagnostic.message,
        )
        lock.lock()
        items.append(mapped)
        lock.unlock()
    }

    func snapshot() -> [PDFParseDiagnostic] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}
