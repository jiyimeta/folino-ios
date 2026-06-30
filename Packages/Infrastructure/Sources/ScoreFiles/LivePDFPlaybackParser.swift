import Domain
import Foundation
import SheetMusicPDF

/// `PDFPlaybackParser` backed by swift-sheet-music's public PDF OMR importer. Reconstructs a playable
/// `Score` plus the on-PDF geometry side-car, and collects the importer's best-effort diagnostics.
///
/// The heavy synchronous OMR pipeline runs on a detached background task so it never blocks the
/// MainActor caller (the Reader awaits the result).
public struct LivePDFPlaybackParser: PDFPlaybackParser {
    public init() {}

    public func parse(pdfURL: URL) async throws -> PDFPlaybackParseResult {
        try await Task.detached(priority: .userInitiated) {
            try Self.parseSynchronously(pdfURL: pdfURL)
        }.value
    }

    private static func parseSynchronously(pdfURL: URL) throws -> PDFPlaybackParseResult {
        let collector = DiagnosticsCollector()
        var options = PDFImportOptions()
        options.diagnostics = { diagnostic in collector.append(diagnostic) }
        do {
            let (score, geometry) = try PDFImporter.parseWithGeometry(pdfURL: pdfURL, options: options)
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
