import Domain
import ImportExport
import Library

/// Pure navigation decision for a completed share-extension drain.
///
/// Extracted from `AppShellView.runDrain` so the post-import routing is unit-testable and depends only on the
/// `DrainResult`. The previous inline logic resolved the score to open by looking its ID up in the
/// asynchronously-observed `repository.scoreItems` snapshot — which had not yet refreshed by the time navigation ran,
/// so a single import silently failed to open. The decision now consumes the `ScoreItem` carried directly by
/// `DrainResult.openAfter`, never a repository lookup.
enum ShareDrainNavigation: Equatable {
    /// Stay put — the user chose not to open, or nothing actionable was imported.
    case none
    /// Multi-file import: surface the destination list rather than a single score.
    case openList(LibraryRoute)
    /// Single import (or dedupe-to-existing): open the score in the Reader, with `playlistUnderneath` pushed first so
    /// the Back affordance lands on the target playlist.
    case openReader(item: ScoreItem, playlistUnderneath: LibraryRoute?)

    static func decide(for result: DrainResult, openAfter: Bool) -> ShareDrainNavigation {
        guard openAfter else { return .none }
        if result.imported.count >= 2 {
            let route = result.targetPlaylistID.map(LibraryRoute.playlistDetail) ?? .allScores
            return .openList(route)
        }
        guard let item = result.openAfter else { return .none }
        let playlistUnderneath = result.targetPlaylistID.map(LibraryRoute.playlistDetail)
        return .openReader(item: item, playlistUnderneath: playlistUnderneath)
    }
}
