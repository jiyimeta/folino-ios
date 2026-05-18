import Foundation

/// Notifies an out-of-process consumer (the Share Extension) about the current Library playlist set. The live
/// implementation in `ImportExport` writes the snapshot to a shared App Group file; tests can use a no-op stub.
public protocol PlaylistsIndexPublisher: Sendable {
    func publish(playlists: [Playlist]) async
}
