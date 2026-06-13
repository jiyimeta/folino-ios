import SwiftUI

/// The Library root's fixed "browse" section: All Scores, Favorites, and Recently Deleted entry points. Counts are
/// passed in as narrow `Int` inputs so the section invalidates only when one of them changes, not on every repository
/// update — see the sibling `LibraryRootPlaylistsSection` / `LibraryRootTagsSection` for the same factoring.
struct LibraryRootBrowseSection: View {
    let scoreCount: Int
    let favoriteCount: Int
    let trashCount: Int

    var body: some View {
        Section {
            NavigationLink(value: LibraryRoute.allScores) {
                browseRow(title: "library.allScores", systemImage: "list.bullet", count: scoreCount)
            }
            if favoriteCount > 0 {
                NavigationLink(value: LibraryRoute.favorites) {
                    browseRow(title: "library.favorites", systemImage: "star.fill", count: favoriteCount)
                }
            }
            if trashCount > 0 {
                NavigationLink(value: LibraryRoute.recentlyDeleted) {
                    browseRow(
                        title: "library.recentlyDeleted.title",
                        systemImage: "trash",
                        count: trashCount,
                    )
                }
            }
        }
    }

    private func browseRow(title: LocalizedStringKey, systemImage: String, count: Int) -> some View {
        HStack {
            Label {
                Text(title, bundle: .module)
            } icon: {
                Image(systemName: systemImage)
                    .foregroundStyle(.tint)
            }
            Spacer()
            Text(count, format: .number)
                .foregroundStyle(.secondary)
        }
    }
}
