import Domain
import Foundation
import ImportExportAppGroup
import os

/// Writes `PlaylistsIndex` atomically to the App Group container so the
/// Share Extension can show the current Library playlists in its picker.
/// Conforms to `PlaylistsIndexPublisher` so it can plug into
/// `LiveScoreLibraryRepository` without that target importing ImportExport.
public final class PlaylistsIndexWriter: PlaylistsIndexPublisher {
    private let appGroupContainer: URL
    private let logger = Logger(subsystem: "com.KeyNumber.Folino", category: "PlaylistsIndexWriter")

    public init(appGroupContainer: URL) {
        self.appGroupContainer = appGroupContainer
    }

    public func publish(playlists: [Playlist]) {
        let entries = playlists.map { PlaylistsIndex.Entry(id: $0.id, name: $0.name) }
        let index = PlaylistsIndex(schemaVersion: 1, playlists: entries)
        do {
            let data = try JSONEncoder().encode(index)
            let destination = AppGroupPaths.playlistsIndexURL(in: appGroupContainer)
            let tmp = destination.appendingPathExtension("tmp")
            try data.write(to: tmp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: tmp)
        } catch {
            logger.error("playlists.json write failed: \(String(describing: error))")
        }
    }
}
