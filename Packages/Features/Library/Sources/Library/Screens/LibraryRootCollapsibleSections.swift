import Domain
import SwiftUI

struct LibraryRootPlaylistsSection: View {
    let allPlaylists: [Playlist]
    let scoreItems: [ScoreItem]

    @AppStorage("library.section.playlists.expanded") private var expanded: Bool = true

    var body: some View {
        if !allPlaylists.isEmpty {
            let total = allPlaylists.count
            let topN = playlistsByRecentlyUsed(allPlaylists, scoreItems: scoreItems, limit: 5)
            Section(isExpanded: $expanded) {
                ForEach(topN) { playlist in
                    NavigationLink(value: LibraryRoute.playlistDetail(playlist.id)) {
                        HStack {
                            Image(systemName: "music.note.list").foregroundStyle(.tint)
                            Text(playlist.name).foregroundStyle(.primary)
                            Spacer()
                            Text(playlist.orderedScoreItemIDs.count, format: .number)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if total > 5 {
                    NavigationLink(value: LibraryRoute.playlists) {
                        HStack {
                            Text("See All", bundle: .module).foregroundStyle(.secondary)
                            Spacer()
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Playlists", bundle: .module)
                    Spacer()
                    Text(total, format: .number).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct LibraryRootTagsSection: View {
    let allTags: [Tag]
    let scoreItems: [ScoreItem]

    @AppStorage("library.section.tags.expanded") private var expanded: Bool = true

    var body: some View {
        if !allTags.isEmpty {
            let total = allTags.count
            let topN = tagsByRecentlyUsed(allTags, scoreItems: scoreItems, limit: 5)
            Section(isExpanded: $expanded) {
                ForEach(topN) { tag in
                    NavigationLink(value: LibraryRoute.tagDetail(tag.id)) {
                        HStack {
                            Image(systemName: "tag.fill").foregroundStyle(.tint)
                            Text(tag.name).foregroundStyle(.primary)
                            Spacer()
                            Text(memberCount(of: tag), format: .number)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if total > 5 {
                    NavigationLink(value: LibraryRoute.tags) {
                        HStack {
                            Text("See All", bundle: .module).foregroundStyle(.secondary)
                            Spacer()
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Tags", bundle: .module)
                    Spacer()
                    Text(total, format: .number).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func memberCount(of tag: Tag) -> Int {
        scoreItems.reduce(0) { acc, item in acc + (item.tagIDs.contains(tag.id) ? 1 : 0) }
    }
}
