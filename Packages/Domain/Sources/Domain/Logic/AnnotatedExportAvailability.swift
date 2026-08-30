import Foundation

/// Which annotated-PDF rows an item offers, given what ink it carries and what documents it has. Pure and shared:
/// iOS's share menu and Android's export sheet call this, so the two cannot disagree about when a row appears.
///
/// One export means one base document, and an item can have been annotated on two of them — the engraved notation
/// (`.musical` anchors) and, for a PDF-origin item, the original pages (`.page` anchors). Rather than pick a base and
/// silently drop the other kind of ink, a row is offered per base that actually carries ink.
public enum AnnotatedExportAvailability {
    /// - Parameters:
    ///   - hasMusicalInk: the layer holds at least one `.musical` drawing anchor.
    ///   - hasPageInk: the layer holds at least one `.page` drawing anchor.
    ///   - hasOriginalPDF: `ScoreItem.originalPDFFileName != nil` — the file the page ink was drawn on is on disk.
    ///   - isEngravable: the item has notation to engrave. False while a PDF import is unconverted
    ///     (`ScoreItem.pdfOriginState == .unconverted`), where there is no score to render whatever the ink says.
    /// - Returns: the annotated formats in display order; empty when the item has nothing to bake.
    public static func formats(
        hasMusicalInk: Bool,
        hasPageInk: Bool,
        hasOriginalPDF: Bool,
        isEngravable: Bool,
    ) -> [ScoreShareFormat] {
        var formats: [ScoreShareFormat] = []
        if hasMusicalInk, isEngravable {
            formats.append(.annotatedPDF)
        }
        if hasPageInk, hasOriginalPDF {
            formats.append(.annotatedOriginalPDF)
        }
        return formats
    }
}
