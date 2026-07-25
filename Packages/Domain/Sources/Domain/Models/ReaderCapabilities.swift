/// What a reader session is allowed to do, derived once from the item's format. PDFs carry no notation *the reader can
/// re-engrave*, so every layout-derivation setting is unavailable; only page and vertical-continuous viewing remain.
///
/// `canPlay` is the format's inherent playability: false for a PDF, because nothing is playable at open time. A PDF can
/// still become playable later, off this axis — the background OMR parse produces a score and the reader consults
/// `ReaderViewModel.canPlayNow` (`canPlay || isPDFPlaybackReady`) for everything transport- and playback-related.
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
}
