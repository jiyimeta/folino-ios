import Domain
import SwiftUI
import UtilityUI

struct LibraryRootPlaylistsSection: View {
    let allPlaylists: [Playlist]
    let scoreItems: [ScoreItem]
    let onRequestDelete: (Playlist) -> Void

    @AppStorage("library.section.playlists.expanded") private var expanded = true

    var body: some View {
        if !allPlaylists.isEmpty {
            let total = allPlaylists.count
            let topN = playlistsByRecentlyUsed(allPlaylists, scoreItems: scoreItems, limit: 5)
            // `scoreItems` is the repository's live snapshot; build the set
            // once so each row's member count excludes soft-deleted items.
            let liveIDs = Set(scoreItems.map(\.id))
            Section {
                if expanded {
                    ForEach(topN) { playlist in
                        NavigationLink(value: LibraryRoute.playlistDetail(playlist.id)) {
                            HStack {
                                Label {
                                    Text(playlist.name)
                                } icon: {
                                    Image(systemName: "music.note.list").foregroundStyle(.tint)
                                }
                                Spacer()
                                Text(liveMemberCount(of: playlist, liveIDs: liveIDs), format: .number)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        // No `role: .destructive` — see `LibraryRootScreen.sectionRow`.
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button {
                                onRequestDelete(playlist)
                            } label: {
                                Label {
                                    L10n.Common.delete
                                } icon: {
                                    Image(systemName: "trash")
                                }
                            }
                            .tint(.red)
                        }
                    }
                    if total > 5 {
                        NavigationLink(value: LibraryRoute.playlists) {
                            HStack {
                                Text("library.seeAll", bundle: .module).foregroundStyle(.secondary)
                                Spacer()
                            }
                        }
                    }
                }
            } header: {
                CollapsibleSectionHeader(
                    title: Text("library.playlists", bundle: .module),
                    count: total,
                    expanded: $expanded,
                )
            }
        }
    }
}

private func liveMemberCount(of playlist: Playlist, liveIDs: Set<ScoreItemID>) -> Int {
    playlist.orderedScoreItemIDs.reduce(0) { acc, id in
        acc + (liveIDs.contains(id) ? 1 : 0)
    }
}

struct LibraryRootTagsSection: View {
    let allTags: [Tag]
    let scoreItems: [ScoreItem]
    let onRequestDelete: (Tag) -> Void

    @AppStorage("library.section.tags.expanded") private var expanded = true

    var body: some View {
        if !allTags.isEmpty {
            let total = allTags.count
            let topN = tagsByRecentlyUsed(allTags, scoreItems: scoreItems, limit: 5)
            Section {
                if expanded {
                    ForEach(topN) { tag in
                        NavigationLink(value: LibraryRoute.tagDetail(tag.id)) {
                            HStack {
                                Label {
                                    Text(tag.name).foregroundStyle(.primary)
                                } icon: {
                                    Image(systemName: "tag").foregroundStyle(.tint)
                                }
                                Spacer()
                                Text(memberCount(of: tag), format: .number)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        // No `role: .destructive` — see `LibraryRootScreen.sectionRow`.
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button {
                                onRequestDelete(tag)
                            } label: {
                                Label {
                                    L10n.Common.delete
                                } icon: {
                                    Image(systemName: "trash")
                                }
                            }
                            .tint(.red)
                        }
                    }
                    if total > 5 {
                        NavigationLink(value: LibraryRoute.tags) {
                            HStack {
                                Text("library.seeAll", bundle: .module).foregroundStyle(.secondary)
                                Spacer()
                            }
                        }
                    }
                }
            } header: {
                CollapsibleSectionHeader(
                    title: Text("library.tags", bundle: .module),
                    count: total,
                    expanded: $expanded,
                )
            }
            .animation(.default, value: expanded)
        }
    }

    private func memberCount(of tag: Tag) -> Int {
        scoreItems.reduce(0) { acc, item in acc + (item.tagIDs.contains(tag.id) ? 1 : 0) }
    }
}

private struct CollapsibleSectionHeader: View {
    let title: Text
    let count: Int
    @Binding var expanded: Bool

    var body: some View {
        Button {
            withAnimation(.snappy) { expanded.toggle() }
        } label: {
            HStack {
                title
                Spacer()
                Text(count, format: .number).foregroundStyle(.secondary)
                Image(systemName: "chevron.down")
                    .font(.footnote.weight(.semibold))
                    .rotationEffect(.degrees(expanded ? 0 : -90))
                    .foregroundStyle(Color.accentColor)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview("Collapsible Sections") {
    List {
        LibraryRootPlaylistsSection(
            allPlaylists: [
                Playlist(name: "Practice", orderedScoreItemIDs: [], createdAt: .now),
                Playlist(name: "Recital", orderedScoreItemIDs: [], createdAt: .now),
            ],
            scoreItems: [],
            onRequestDelete: { _ in },
        )
        LibraryRootTagsSection(
            allTags: [
                Tag(name: "Bach", colorHex: "#FF0000"),
                Tag(name: "Chopin", colorHex: "#00FF00"),
            ],
            scoreItems: [],
            onRequestDelete: { _ in },
        )
    }
    .listStyle(.sidebar)
}
