import Domain
import Foundation
import SheetMusicPDF

/// iOS `ScorePDFRenderer` backed by `swift-sheet-music`'s CoreGraphics `PDFExporter`.
public struct CoreGraphicsPDFRenderer: ScorePDFRenderer {
    public init() {}

    public func renderPDF(score: Score, title: String) async throws -> Data {
        do {
            return try await MainActor.run {
                try PDFExporter.export(score: score, options: PDFExporter.Options(title: title))
            }
        } catch {
            throw DomainError.scoreWriteFailed(reason: "\(error)")
        }
    }
}
