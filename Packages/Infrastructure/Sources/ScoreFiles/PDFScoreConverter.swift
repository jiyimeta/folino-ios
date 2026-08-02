import CryptoKit
import Domain
import Foundation
import UtilityCore

/// The result of reading a PDF into notation.
public enum PDFConversionOutcome: Sendable {
    /// The PDF was read and the score was written.
    case converted(PDFConversionFacts)
    /// The parse threw, or it succeeded but decoded nothing playable — e.g. an OMR pass over a raster "print to PDF"
    /// that finds staff lines but no noteheads. The caller keeps displaying the PDF.
    case notReadable

    public var facts: PDFConversionFacts? {
        if case let .converted(facts) = self { return facts }
        return nil
    }
}

/// Reads a PDF into a `Score` and writes it as `.mscz`. The single implementation of "convert a PDF", shared by
/// import, the Reader's lazy conversion of a PDF imported before folino could read one, and the explicit re-read — so
/// the three can never drift apart.
///
/// The written file is re-read through `loadFileMetadata` rather than deriving a summary from the parsed `Score`, so a
/// converted item's metadata comes from exactly the same path as a natively imported `.mscz`.
public struct PDFScoreConverter: Sendable {
    private let parser: any PDFPlaybackParser
    private let gateway: any ScoreFileGateway
    private let crashReporter: any CrashReporter

    public init(
        parser: any PDFPlaybackParser,
        gateway: any ScoreFileGateway,
        crashReporter: any CrashReporter = NoopCrashReporter(),
    ) {
        self.parser = parser
        self.gateway = gateway
        self.crashReporter = crashReporter
    }

    public func convert(pdfURL: URL, destinationMSCZ: URL) async -> PDFConversionOutcome {
        do {
            let result = try await parser.parse(pdfURL: pdfURL)
            // A structurally complete but silent parse is not a score anyone can use. Same threshold both platforms
            // apply to deciding a PDF is playable.
            guard result.score.hasPlayableContent else { return .notReadable }
            try await gateway.saveScore(result.score, fileURL: destinationMSCZ, format: .mscz)
            let summary = try await gateway.loadFileMetadata(fileURL: destinationMSCZ)
            let (hash, size) = try Self.hashAndSize(destinationMSCZ)
            return .converted(PDFConversionFacts(
                fileName: destinationMSCZ.lastPathComponent,
                contentHash: hash,
                sizeBytes: size,
                summary: summary,
            ))
        } catch {
            // Any failure leaves the caller exactly where it was, including no half-written destination.
            //
            // Reported as a non-fatal because the user-visible symptom — "folino couldn't read this PDF" — is the same
            // whether the OMR found no music or the score it found could not be written and read back. Only the error
            // separates them, and without it a defect in the write/read round-trip is indistinguishable from a PDF
            // that genuinely isn't sheet music. (That is not hypothetical: a tuplet the importer scaled but never
            // recorded produced an `.mscz` its own reader rejected, and playback worked the whole time.)
            crashReporter.record(error: error)
            try? FileManager.default.removeItem(at: destinationMSCZ)
            return .notReadable
        }
    }

    private static func hashAndSize(_ url: URL) throws -> (String, Int64) {
        var hasher = SHA256()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var total: Int64 = 0
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
            total += Int64(chunk.count)
        }
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), total)
    }
}
