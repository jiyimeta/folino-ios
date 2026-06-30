import Wirelet

/// Result of `LibraryAndroidStore.importShared`, marshaled to Kotlin. `openAfterId` is `""` when nothing should open.
///
/// The three `analytics*` arrays carry the facts needed to log the per-file `score_imported` / `score_import_failed`
/// events on the Kotlin side (which owns the Firebase call). They are kept as flat parallel `[String]` arrays — not
/// nested wire events — so Kotlin only relays Swift-authored tokens to the `AnalyticsBridge` builders, which produce
/// the actual wire events. `analyticsImportedFormats` holds one `ScoreFormat` case-name token per successfully
/// imported (non-duplicate) file; `analyticsFailedFormats` / `analyticsFailedReasons` are the parallel
/// format-token + already-resolved reason-string for each failed (non-duplicate) file. Duplicates are skipped and
/// logged by neither (iOS parity).
@WireFormat
public struct ImportSharedResultWire: Equatable, Sendable {
    public var importedCount: Int32
    public var skippedCount: Int32
    public var openAfterId: String
    public var createdPlaylistId: String
    public var targetPlaylistId: String
    public var playlistCreateFailureName: String
    public var analyticsImportedFormats: [String]
    public var analyticsFailedFormats: [String]
    public var analyticsFailedReasons: [String]

    public init(
        importedCount: Int32,
        skippedCount: Int32,
        openAfterId: String,
        createdPlaylistId: String,
        targetPlaylistId: String,
        playlistCreateFailureName: String,
        analyticsImportedFormats: [String] = [],
        analyticsFailedFormats: [String] = [],
        analyticsFailedReasons: [String] = [],
    ) {
        self.importedCount = importedCount
        self.skippedCount = skippedCount
        self.openAfterId = openAfterId
        self.createdPlaylistId = createdPlaylistId
        self.targetPlaylistId = targetPlaylistId
        self.playlistCreateFailureName = playlistCreateFailureName
        self.analyticsImportedFormats = analyticsImportedFormats
        self.analyticsFailedFormats = analyticsFailedFormats
        self.analyticsFailedReasons = analyticsFailedReasons
    }
}
