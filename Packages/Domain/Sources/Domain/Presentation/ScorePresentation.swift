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
    /// Whether the library row and reader header should mark this item as PDF-derived. Stays true after folino reads
    /// the PDF into notation: the badge's job is to say "this was machine-read and may contain mistakes", which a
    /// converted item needs more than an unconverted one, not less.
    public static func showsPDFBadge(for item: ScoreItem) -> Bool {
        item.pdfOriginState != .notPDF
    }

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

    /// PDF counterpart of `displayFields(sourceFilename:score:)`. A PDF has no decoded notation at import time
    /// (that happens later, in the Reader, via OMR), so subtitle and composer are left nil.
    ///
    /// The title comes from the file name, NOT the document's `/Title` attribute. `/Title` looks like the better
    /// signal and isn't: exporters bake their own internal project name into it, so a file the user filed away as
    /// `spring-song.pdf` arrives titled `アイデア#0131`. The file name is what the user chose. Both platforms go
    /// through here so neither can quietly reinstate the `/Title` preference for itself.
    public static func displayFields(sourceFilename: String) -> ScoreDisplayFields {
        ScoreDisplayFields(
            title: title(fromFilename: sourceFilename),
            subtitle: nil,
            composer: nil,
        )
    }
}
