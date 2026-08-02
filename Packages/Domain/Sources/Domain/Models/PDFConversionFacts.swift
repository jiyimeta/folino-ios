import Foundation

/// Everything a caller needs to update a library row after a PDF has been read into notation and written to disk.
///
/// It lives in Domain rather than next to the converter so the Reader can speak it without importing Infrastructure:
/// the App hands the Reader a closure that returns this, and the module boundary holds.
public struct PDFConversionFacts: Sendable {
    /// File name of the score that was written, relative to the scores directory.
    public let fileName: String
    /// SHA-256 of the written score's bytes.
    public let contentHash: String
    public let sizeBytes: Int64
    /// Metadata read back out of the written score, so a converted item is described by exactly the same code that
    /// describes a natively imported one.
    public let summary: ScoreFileSummary

    public init(fileName: String, contentHash: String, sizeBytes: Int64, summary: ScoreFileSummary) {
        self.fileName = fileName
        self.contentHash = contentHash
        self.sizeBytes = sizeBytes
        self.summary = summary
    }
}

/// Reads the PDF at `pdfURL` into notation and writes it to `destinationMSCZ`, answering the facts needed to update
/// the library row — or `nil` when the PDF can't be read as music.
///
/// A closure rather than a protocol so the two callers that need it (the importer in `Persistence`, the Reader
/// feature) can take it without either depending on the `ScoreFiles` target that owns the implementation. The App
/// builds it from `PDFScoreConverter`.
public typealias PDFScoreConversion = @Sendable (_ pdfURL: URL, _ destinationMSCZ: URL) async -> PDFConversionFacts?
