import Wirelet

/// Result of `LibraryAndroidStore.importShared`, marshaled to Kotlin. `openAfterId` is `""` when nothing should open.
@WireFormat
public struct ImportSharedResultWire: Equatable, Sendable {
    public var importedCount: Int32
    public var skippedCount: Int32
    public var openAfterId: String
    public var createdPlaylistId: String
    public var targetPlaylistId: String
    public var playlistCreateFailureName: String

    public init(
        importedCount: Int32,
        skippedCount: Int32,
        openAfterId: String,
        createdPlaylistId: String,
        targetPlaylistId: String,
        playlistCreateFailureName: String,
    ) {
        self.importedCount = importedCount
        self.skippedCount = skippedCount
        self.openAfterId = openAfterId
        self.createdPlaylistId = createdPlaylistId
        self.targetPlaylistId = targetPlaylistId
        self.playlistCreateFailureName = playlistCreateFailureName
    }
}
