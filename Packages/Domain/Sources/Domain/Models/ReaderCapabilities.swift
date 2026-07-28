/// What a reader session is allowed to do, derived once from the item's format. PDFs carry no notation *the reader can
/// re-engrave*, so every layout-derivation setting is unavailable; only page and vertical-continuous viewing remain.
///
/// `canPlay` is the format's inherent playability: false for a PDF, because nothing is playable at open time. A PDF can
/// still become playable later, off this axis — the background OMR parse produces a score and the reader consults
/// `canPlayNow(capabilities:isPDFPlaybackReady:)` for everything transport- and playback-related. iOS reads it through
/// `ReaderViewModel.canPlayNow`; Android through `nativeCanPlayNow`.
public struct ReaderCapabilities: Hashable, Sendable {
    public var canPlay: Bool
    public var canChangeLayout: Bool
    public var canTranspose: Bool
    public var canEditStaves: Bool
    public var availableLayoutModes: [ReaderLayoutMode]

    public static let forScore = ReaderCapabilities(
        canPlay: true,
        canChangeLayout: true,
        canTranspose: true,
        canEditStaves: true,
        availableLayoutModes: [.vertical, .horizontal, .page],
    )

    public static let forPDF = ReaderCapabilities(
        canPlay: false,
        canChangeLayout: false,
        canTranspose: false,
        canEditStaves: false,
        availableLayoutModes: [.page, .vertical],
    )

    public static func resolve(format: ScoreFormat?) -> ReaderCapabilities {
        format == .pdf ? .forPDF : .forScore
    }

    /// Whether a reader session may play right now. A score is playable from its format alone; a PDF only
    /// after the background OMR parse succeeds. iOS reads this through `ReaderViewModel.canPlayNow`; Android
    /// through `nativeCanPlayNow`. One rule, both platforms.
    public static func canPlayNow(capabilities: ReaderCapabilities, isPDFPlaybackReady: Bool) -> Bool {
        capabilities.canPlay || isPDFPlaybackReady
    }

    /// Whether a PDF's background OMR parse yielded enough to call itself playable, given how many
    /// playable elements (chords with at least one note) it reconstructed. This is the ONE place that
    /// threshold is decided — `Score.hasPlayableContent` (iOS, which has the parsed `Score` on hand) and
    /// Android's `nativeIsPlayableElementCount` (which only ever crosses the JNI boundary with a raw
    /// count, computed independently by swift-sheet-music's importer) both route through this, so a
    /// structurally-complete-but-silent parse — e.g. an OMR pass over a raster "print to PDF" export that
    /// reads staff lines but decodes no noteheads — reports the identical verdict on both platforms.
    public static func isPlayableElementCount(_ count: Int) -> Bool {
        count > 0
    }
}
