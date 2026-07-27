import Foundation
import SheetMusicCore

/// Display fields for a library score row, derived from the import-time
/// inputs (the source file name and the parsed `Score`).
///
/// This is the single source of truth for "what a freshly-imported score
/// shows in the library", shared by the iOS importer and the Android store so
/// the two platforms cannot drift. The rules mirror the iOS Library:
/// the title is the source file name (rename is a separate user action),
/// the subtitle comes from the score's title frame, and the composer comes
/// from the `composer` metaTag.
public struct ScoreDisplayFields: Equatable, Sendable {
    public var title: String
    public var subtitle: String?
    public var composer: String?

    public init(title: String, subtitle: String?, composer: String?) {
        self.title = title
        self.subtitle = subtitle
        self.composer = composer
    }
}

public enum ScorePresentation {
    /// The library title: the source file's name without its extension.
    /// (The score's `workTitle` metaTag is deliberately not used — rename is a
    /// separate user action.)
    public static func title(fromFilename filename: String) -> String {
        URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
    }

    /// Subtitle from the score's title frame (`<VBox>`/`<Text>` carrying
    /// `<style>Subtitle</style>`).
    public static func subtitle(from score: Score) -> String? {
        let texts = score.titleFrame?.texts ?? []
        return nonEmpty(texts.first(where: { $0.style == .subtitle })?.text)
    }

    /// Composer from the `composer` metaTag.
    public static func composer(from score: Score) -> String? {
        nonEmpty(score.metaTags["composer"])
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    /// Convenience that assembles every row field at once (used by the Android
    /// store; the iOS importer composes the same pieces alongside the other
    /// `ScoreFileSummary` fields).
    public static func displayFields(sourceFilename: String, score: Score) -> ScoreDisplayFields {
        ScoreDisplayFields(
            title: title(fromFilename: sourceFilename),
            subtitle: subtitle(from: score),
            composer: composer(from: score),
        )
    }

    /// The library title for a PDF import: the document's own `/Title` attribute when present, else the
    /// filename-derived title. A PDF is imported as a fixed-layout document with no notation decoded yet (that
    /// happens later, in the Reader, via OMR), so `/Title` is the only metadata signal available at import time.
    /// Shared by the iOS importer (`ScoreFileGateway.pdfSummary`'s `summary.title`) and the Android PDF import
    /// path (`PDFImporter.summaryUsingSwiftReader(pdfData:)`'s `PDFDocumentSummary.title`) so neither platform
    /// keeps its own copy of the rule.
    public static func title(fromFilename filename: String, pdfTitle: String?) -> String {
        nonEmpty(pdfTitle) ?? title(fromFilename: filename)
    }

    /// PDF counterpart of `displayFields(sourceFilename:score:)`. No musical metadata exists at import time, so
    /// only the title rule applies; subtitle/composer are left nil.
    public static func displayFields(sourceFilename: String, pdfTitle: String?) -> ScoreDisplayFields {
        ScoreDisplayFields(
            title: title(fromFilename: sourceFilename, pdfTitle: pdfTitle),
            subtitle: nil,
            composer: nil,
        )
    }
}
