/// What a reader session is allowed to do, derived once from the item's format. PDFs carry no notation, so playback
/// and all layout-derivation settings are unavailable; only page and vertical-continuous viewing remain. This is the
/// single source of truth the reader UI consults — when PDF gains parsed playback later, only `resolve` changes.
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
