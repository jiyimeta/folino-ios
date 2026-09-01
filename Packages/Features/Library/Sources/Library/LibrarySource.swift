import Domain
import Foundation

/// One entry in the Mac browser's sidebar. The fixed sources (`recents`, `allScores`, `favorites`,
/// `recentlyDeleted`) always exist; `playlist` and `tag` are one case per live `Playlist` / `Tag`.
enum LibrarySource: Hashable, Identifiable {
    case recents
    case allScores
    case favorites
    case playlist(PlaylistID)
    case tag(TagID)
    case recentlyDeleted

    var id: Self {
        self
    }
}

/// One row in the Mac browser's sidebar, as `LibrarySourceList.rows` orders and counts it.
struct LibrarySourceRow: Identifiable, Equatable {
    let source: LibrarySource
    let title: String
    let count: Int

    var id: LibrarySource {
        source
    }
}

/// Builds the Mac browser's sidebar rows from the library's live state. Platform-neutral — the browser window is a
/// Mac-only surface, but this list itself has no UI dependency and is tested on iOS.
enum LibrarySourceList {
    /// Rows in sidebar order, top to bottom: `recents`, `allScores`, `favorites`, then one row per playlist (in
    /// `playlists` order), then one row per tag (in `tags` order), then `recentlyDeleted`.
    ///
    /// Playlist and tag counts exclude soft-deleted items — `PlaylistsListView`'s `memberCount` doc comment states
    /// the same contract for iOS, and the Mac sidebar must not diverge from it.
    static func rows(
        scoreItems: [ScoreItem],
        deletedScoreItems: [ScoreItem],
        playlists: [Playlist],
        tags: [Tag],
    ) -> [LibrarySourceRow] {
        let liveIDs = Set(scoreItems.map(\.id))

        var rows: [LibrarySourceRow] = [
            LibrarySourceRow(
                source: .recents,
                title: String(localized: "library.recentlyOpened", bundle: .module),
                count: scoreItems.count(where: { $0.lastOpenedAt != nil }),
            ),
            LibrarySourceRow(
                source: .allScores,
                title: String(localized: "library.allScores", bundle: .module),
                count: scoreItems.count,
            ),
            LibrarySourceRow(
                source: .favorites,
                title: String(localized: "library.favorites", bundle: .module),
                count: scoreItems.count(where: \.isFavorite),
            ),
        ]

        for playlist in playlists {
            let liveMemberCount = playlist.orderedScoreItemIDs.count(where: { liveIDs.contains($0) })
            rows.append(
                LibrarySourceRow(source: .playlist(playlist.id), title: playlist.name, count: liveMemberCount),
            )
        }

        for tag in tags {
            let liveTagCount = scoreItems.count(where: { $0.tagIDs.contains(tag.id) })
            rows.append(LibrarySourceRow(source: .tag(tag.id), title: tag.name, count: liveTagCount))
        }

        rows.append(
            LibrarySourceRow(
                source: .recentlyDeleted,
                title: String(localized: "library.recentlyDeleted.title", bundle: .module),
                count: deletedScoreItems.count,
            ),
        )

        return rows
    }
}
