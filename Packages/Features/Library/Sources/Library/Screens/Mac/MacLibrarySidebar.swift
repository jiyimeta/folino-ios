#if os(macOS)
import Domain
import SwiftUI
import UtilityUI

/// The Mac library browser's source sidebar — the flat list of Recents / All Scores / Favorites / each playlist /
/// each tag / Recently Deleted. `LibrarySourceList` (see `LibrarySource.swift`) already resolves titles, counts, and
/// ordering; this view only presents the resulting rows and lets the user rename/delete a playlist or tag.
///
/// **No `NavigationLink`, no `NavigationStack`, no tap gesture anywhere in this file.** `List(selection:)` plus each
/// row's `.tag(_:)` is the entire selection vocabulary. See `RowOpenAffordance.swift`'s doc comment for the
/// measurements behind both prohibitions: a `NavigationStack` pushed inside a `NavigationSplitView` sidebar renders
/// bottom-anchored on macOS 26.4.1, and any tap gesture on a `List(selection:)` row leaves the selection permanently
/// empty.
struct MacLibrarySidebar: View {
    let viewModel: LibraryViewModel
    @Binding var selection: LibrarySource?

    @State private var renameTarget: LibrarySourceRow?
    @State private var renameText = ""
    @State private var deleteTarget: LibrarySourceRow?

    init(viewModel: LibraryViewModel, selection: Binding<LibrarySource?>) {
        self.viewModel = viewModel
        _selection = selection
    }

    var body: some View {
        List(selection: $selection) {
            ForEach(rows) { row in
                rowContent(for: row)
            }
        }
        .listStyle(.sidebar)
        .alert(
            Text(renameCopy.renameTitleKey, bundle: .module),
            isPresented: isRenamingBinding,
        ) {
            TextField(text: $renameText) {
                Text(renameCopy.renamePlaceholderKey, bundle: .module)
            }
            Button {
                commitPendingRename()
            } label: { L10n.Common.save }
            Button(role: .cancel) {} label: { L10n.Common.cancel }
        }
        .alert(
            Text(String(
                localized: "library.score.delete.title",
                defaultValue: "Delete \"\(deleteTarget?.title ?? "")\"?",
                bundle: .module,
            )),
            isPresented: isDeletingBinding,
        ) {
            Button(role: .destructive) {
                commitPendingDelete()
            } label: { L10n.Common.delete }
            Button(role: .cancel) {} label: { L10n.Common.cancel }
        } message: {
            Text(deleteCopy.deleteMessageKey, bundle: .module)
        }
    }

    private var rows: [LibrarySourceRow] {
        LibrarySourceList.rows(
            scoreItems: viewModel.repository.scoreItems,
            deletedScoreItems: viewModel.repository.deletedScoreItems,
            playlists: viewModel.repository.playlists,
            tags: viewModel.repository.tags,
        )
    }

    /// One row's label, with a Rename/Delete context menu on playlist and tag rows only — the fixed sources have
    /// nothing to rename or delete.
    @ViewBuilder
    private func rowContent(for row: LibrarySourceRow) -> some View {
        let label = Label {
            Text(row.title)
        } icon: {
            Image(systemName: icon(for: row.source))
        }
        .badge(row.count)
        .tag(row.source)

        switch row.source {
        case .playlist, .tag:
            label.contextMenu {
                Button {
                    renameText = row.title
                    renameTarget = row
                } label: {
                    Label {
                        L10n.Common.rename
                    } icon: {
                        Image(systemName: "pencil")
                    }
                }
                Button(role: .destructive) {
                    deleteTarget = row
                } label: {
                    Label {
                        L10n.Common.delete
                    } icon: {
                        Image(systemName: "trash")
                    }
                }
            }
        case .recents, .allScores, .favorites, .recentlyDeleted:
            label
        }
    }

    private func icon(for source: LibrarySource) -> String {
        switch source {
        case .recents: "clock"
        case .allScores: "music.note.list"
        case .favorites: "star"
        case .playlist: "music.note.list"
        case .tag: "tag"
        case .recentlyDeleted: "trash"
        }
    }

    /// The rename/delete copy for whichever row is currently targeted — playlist and tag each have their own
    /// localized title/placeholder/message, matching `ManageEntityCopy.playlist` / `.tag` used on the detail screens.
    /// Falls back to `.playlist` when nothing is targeted; the fallback is never shown since the alerts are gated on
    /// `renameTarget` / `deleteTarget` being non-nil.
    private var renameCopy: ManageEntityCopy {
        switch renameTarget?.source {
        case .tag: .tag
        default: .playlist
        }
    }

    private var deleteCopy: ManageEntityCopy {
        switch deleteTarget?.source {
        case .tag: .tag
        default: .playlist
        }
    }

    private var isRenamingBinding: Binding<Bool> {
        Binding(
            get: { renameTarget != nil },
            set: { isPresented in
                if !isPresented {
                    renameTarget = nil
                }
            },
        )
    }

    private var isDeletingBinding: Binding<Bool> {
        Binding(
            get: { deleteTarget != nil },
            set: { isPresented in
                if !isPresented {
                    deleteTarget = nil
                }
            },
        )
    }

    private func commitPendingRename() {
        guard let target = renameTarget else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != target.title else { return }
        Task { await commitRename(target, to: trimmed) }
    }

    private func commitPendingDelete() {
        guard let target = deleteTarget else { return }
        Task { await commitDelete(target) }
    }

    /// Mirrors `PlaylistDetailScreen.commitRename` / `TagDetailScreen.commitRename` — the sidebar has no
    /// `LibraryViewModel`-level rename method to call (there isn't one; those screens write through
    /// `viewModel.repository` directly), so this reuses the same repository call and analytics event rather than
    /// inventing a new view-model method.
    private func commitRename(_ row: LibrarySourceRow, to newName: String) async {
        switch row.source {
        case let .playlist(id):
            guard var playlist = viewModel.repository.playlists.first(where: { $0.id == id }) else { return }
            playlist.name = newName
            do {
                try await viewModel.repository.savePlaylist(playlist)
                viewModel.analytics.log(.playlistRenamed(source: .playlist))
            } catch {
                viewModel.currentError = error
            }
        case let .tag(id):
            guard var tag = viewModel.repository.tags.first(where: { $0.id == id }) else { return }
            tag.name = newName
            do {
                try await viewModel.repository.saveTag(tag)
                viewModel.analytics.log(.tagRenamed(source: .tag))
            } catch {
                viewModel.currentError = error
            }
        case .recents, .allScores, .favorites, .recentlyDeleted:
            return
        }
    }

    /// Reuses `LibraryViewModel.deletePlaylist` / `.deleteTag` — the exact calls `PlaylistsListScreen` /
    /// `TagsListScreen` make for the same rows on iOS.
    private func commitDelete(_ row: LibrarySourceRow) async {
        switch row.source {
        case let .playlist(id):
            guard let playlist = viewModel.repository.playlists.first(where: { $0.id == id }) else { return }
            await viewModel.deletePlaylist(playlist)
        case let .tag(id):
            guard let tag = viewModel.repository.tags.first(where: { $0.id == id }) else { return }
            await viewModel.deleteTag(tag)
        case .recents, .allScores, .favorites, .recentlyDeleted:
            return
        }
    }
}

#if DEBUG
/// Minimal in-memory repository so the preview is self-contained (no App composition root needed), mirroring
/// `NewScoreSheet+Previews.swift`'s `PreviewScoreLibraryRepository`. Populated so every fixed row and one playlist /
/// tag row show a nonzero badge.
@MainActor
@Observable
private final class PreviewMacLibrarySidebarRepository: ScoreLibraryRepository {
    private static let openScore = MacLibrarySidebarPreviewFactory.item(
        title: "Trio in D", summary: "Violin, Viola, Cello", lastOpenedAt: Date(), isFavorite: true,
        tagIDs: [PreviewMacLibrarySidebarRepository.practiceTag.id],
    )
    private static let otherScore = MacLibrarySidebarPreviewFactory.item(
        title: "Ballad", summary: "Voice, Piano", lastOpenedAt: nil, isFavorite: false, tagIDs: [],
    )
    private static let practiceTag = Tag(name: "Practice", colorHex: "#5856D6")

    var scoreItems: [ScoreItem] = [openScore, otherScore]
    var deletedScoreItems: [ScoreItem] = [
        MacLibrarySidebarPreviewFactory.item(
            title: "Retired sketch", summary: "Piano", lastOpenedAt: nil, isFavorite: false, tagIDs: [],
            deletedAt: Date(),
        ),
    ]
    var tags: [Tag] = [practiceTag]
    var playlists: [Playlist] = [
        Playlist(name: "Daily warm-up", orderedScoreItemIDs: [openScore.id], createdAt: Date()),
    ]

    func refresh() {}
    func saveScoreItem(_: ScoreItem) {}
    func deleteScoreItem(id _: ScoreItemID) {}
    func softDeleteScoreItem(id _: ScoreItemID) {}
    func restoreScoreItem(id _: ScoreItemID) {}
    func permanentlyDeleteScoreItem(id _: ScoreItemID) {}
    func pruneScoreItemsDeleted(before _: Date) {}
    func saveTag(_: Tag) {}
    func deleteTag(id _: TagID) {}
    func savePlaylist(_: Playlist) {}
    func deletePlaylist(id _: PlaylistID) {}
    func scoreItems(matchingContentHash _: String) -> [ScoreItem] {
        []
    }

    func loadReaderPreferences(for _: ScoreItemID) -> ReaderPreferences? {
        nil
    }

    func saveReaderPreferences(_: ReaderPreferences) {}
    func allReaderPreferences() -> [ReaderPreferences] {
        []
    }
}

private enum MacLibrarySidebarPreviewFactory {
    static func item(
        title: String, summary: String, lastOpenedAt: Date?, isFavorite: Bool, tagIDs: Set<TagID>,
        deletedAt: Date? = nil,
    ) -> ScoreItem {
        ScoreItem(
            title: title, composer: nil, instrumentationSummary: summary,
            localFileName: "\(title).mscx", contentHash: title,
            sizeBytes: 0, lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: Date(timeIntervalSince1970: 1_700_000_000), lastOpenedAt: lastOpenedAt,
            tagIDs: tagIDs, isFavorite: isFavorite, deletedAt: deletedAt,
        )
    }
}

@MainActor
private func previewMacLibrarySidebarViewModel() -> LibraryViewModel {
    LibraryViewModel(
        repository: PreviewMacLibrarySidebarRepository(),
        originalStore: PreviewMacLibrarySidebarOriginalStore(),
        importer: PreviewMacLibrarySidebarFileImporter(),
        gateway: PreviewMacLibrarySidebarFileGateway(),
        shareService: PreviewMacLibrarySidebarShareService(),
        metadataReader: PreviewMacLibrarySidebarMetadataReading(),
        creator: PreviewMacLibrarySidebarFileCreator(),
        scoresDirectory: URL(filePath: "/tmp"),
    )
}

/// None of these adapters are exercised by rendering the sidebar — it only reads `viewModel.repository` and calls
/// rename/delete, neither of which a static preview drives — so every method is a stub, as in
/// `NewScoreSheet+Previews.swift`.
private struct PreviewMacLibrarySidebarOriginalStore: ScoreOriginalStore {
    func captureOriginalIfNeeded(for item: ScoreItem) -> ScoreItem {
        item
    }

    func revertToOriginal(_ item: ScoreItem, restoringScoreInfo _: Bool) -> ScoreItem {
        item
    }

    func discardOriginal(for item: ScoreItem) -> ScoreItem {
        item
    }
}

private struct PreviewMacLibrarySidebarFileImporter: ScoreFileImporter {
    func prepareImport(sourceURL _: URL) throws -> ImportPlan {
        throw DomainError.unsupportedFormat("preview")
    }

    func commitImport(_: ImportPlan, decision _: ImportDecision) throws -> ScoreItem {
        throw DomainError.unsupportedFormat("preview")
    }
}

private struct PreviewMacLibrarySidebarFileGateway: ScoreFileGateway {
    func detectFormat(fileName _: String) -> ScoreFormat? {
        nil
    }

    func loadFileMetadata(fileURL _: URL) throws -> ScoreFileSummary {
        throw DomainError.unsupportedFormat("preview")
    }

    func loadScore(fileURL _: URL) throws -> (score: Score, summary: ScoreFileSummary) {
        throw DomainError.unsupportedFormat("preview")
    }

    func saveScore(_: Score, fileURL _: URL, format: ScoreFormat) throws {
        throw DomainError.unsupportedFormat(format.canonicalExtension)
    }
}

private struct PreviewMacLibrarySidebarShareService: ScoreShareService {
    func availableFormats(for _: ScoreItem) -> [ScoreShareFormatOption] {
        []
    }

    func prepareShare(item _: ScoreItem, format: ScoreShareFormat) throws -> URL {
        throw DomainError.unsupportedFormat(format.canonicalExtension)
    }
}

private struct PreviewMacLibrarySidebarMetadataReading: ScoreMetadataReading {
    func readMetadata(for _: ScoreItem) throws -> ScoreFileMetadata {
        throw DomainError.unsupportedFormat("preview")
    }
}

private struct PreviewMacLibrarySidebarFileCreator: ScoreFileCreator {
    func createScore(_: Score) throws -> ScoreItem {
        throw DomainError.unsupportedFormat("preview")
    }
}

#Preview("Sidebar") {
    MacLibrarySidebar(viewModel: previewMacLibrarySidebarViewModel(), selection: .constant(.allScores))
        .frame(width: 260, height: 480)
}
#endif
#endif
