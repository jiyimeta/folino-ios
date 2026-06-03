import Foundation
import SheetMusicCore

/// Renders a parsed `Score` to PDF bytes. Injected so the share service stays free of any platform graphics import
/// (CoreGraphics on iOS, `PdfDocument` on Android). Errors throw `DomainError.scoreWriteFailed`.
public protocol ScorePDFRenderer: Sendable {
    /// Render `score` to PDF data. `title` is the display title (used for any in-PDF metadata/header).
    func renderPDF(score: Score, title: String) async throws -> Data
}
