import Domain
import SwiftUI
import UniformTypeIdentifiers
import UtilityUI

@MainActor
public struct LibraryRootScreen<LicenseContent: View, ReaderContent: View, LeadingToolbar: View>: View {
    @Bindable var viewModel: LibraryViewModel
    @Binding private var path: NavigationPath
    private let onOpenScore: (ScoreItem) -> Void
    private let readerDestination: (ScoreItem) -> ReaderContent
    private let licenseContent: () -> LicenseContent
    private let leadingToolbarItem: () -> LeadingToolbar

    @State private var editTagsTarget: ScoreItem?
    @State private var addToPlaylistTarget: ScoreItem?

    @State private var isCreatingPlaylist: Bool = false
    @State private var newPlaylistName: String = ""
    @State private var isCreatingTag: Bool = false
    @State private var newTagName: String = ""

    @State private var pendingDeletePlaylist: Playlist?
    @State private var pendingDeleteTag: Tag?
    @State private var pendingDeleteScore: ScoreItem?

    public init(
        viewModel: LibraryViewModel,
        path: Binding<NavigationPath>,
        onOpenScore: @escaping (ScoreItem) -> Void,
        @ViewBuilder readerDestination: @escaping (ScoreItem) -> ReaderContent,
        @ViewBuilder licenseContent: @escaping () -> LicenseContent,
        @ViewBuilder leadingToolbarItem: @escaping () -> LeadingToolbar = { EmptyView() }
    ) {
        self.viewModel = viewModel
        _path = path
        self.onOpenScore = onOpenScore
        self.readerDestination = readerDestination
        self.licenseContent = licenseContent
        self.leadingToolbarItem = leadingToolbarItem
    }

    public var body: some View {
        NavigationStack(path: $path) {
            rootList
                .navigationTitle(Text("library.title", bundle: .module))
                .toolbar { leadingToolbar }
                .toolbar { importToolbar }
                .fileImporter(
                    isPresented: $viewModel.isFileImporterPresented,
                    allowedContentTypes: ScoreFileTypes.allowed,
                    allowsMultipleSelection: false
                ) { result in
                    switch result {
                    case let .success(urls):
                        guard let url = urls.first else { return }
                        Task { await viewModel.startImport(from: url) }
                    case let .failure(error):
                        viewModel.errorAlertMessage = error.localizedDescription
                    }
                }
                .navigationDestination(for: LibraryRoute.self) { route in
                    libraryRootDestination(
                        for: route,
                        viewModel: viewModel,
                        onOpenScore: onOpenScore,
                        onEditTags: { editTagsTarget = $0 },
                        onAddToPlaylist: { addToPlaylistTarget = $0 }
                    )
                }
                .navigationDestination(for: ScoreItem.self) { item in
                    readerDestination(item)
                }
        }
        .sheet(item: $editTagsTarget) { item in
            EditTagsScreen(scoreItem: item, library: viewModel)
        }
        .sheet(item: $addToPlaylistTarget) { item in
            AddToPlaylistScreen(scoreItem: item, library: viewModel)
        }
        .alert(
            Text("library.title", bundle: .module),
            isPresented: errorAlertBinding,
            presenting: viewModel.errorAlertMessage
        ) { _ in
            Button { viewModel.errorAlertMessage = nil } label: {
                L10n.Common.ok
            }
        } message: { msg in
            Text(msg)
        }
        .alert(Text("library.playlist.create.title", bundle: .module), isPresented: $isCreatingPlaylist) {
            TextField(text: $newPlaylistName) { Text("library.playlist.namePlaceholder", bundle: .module) }
            Button {
                let name = newPlaylistName
                newPlaylistName = ""
                Task { await viewModel.createPlaylist(name: name) }
            } label: { L10n.Common.add }
            Button(role: .cancel) { newPlaylistName = "" } label: { L10n.Common.cancel }
        } message: {
            Text("library.playlist.create.message", bundle: .module)
        }
        .alert(Text("library.tag.create.title", bundle: .module), isPresented: $isCreatingTag) {
            TextField(text: $newTagName) { Text("library.tag.namePlaceholder", bundle: .module) }
            Button {
                let name = newTagName
                newTagName = ""
                Task { await viewModel.createTag(name: name) }
            } label: { L10n.Common.add }
            Button(role: .cancel) { newTagName = "" } label: { L10n.Common.cancel }
        } message: {
            Text("library.tag.create.message", bundle: .module)
        }
        .libraryRootDeleteAlerts(
            viewModel: viewModel,
            pendingDeletePlaylist: $pendingDeletePlaylist,
            pendingDeleteTag: $pendingDeleteTag,
            pendingDeleteScore: $pendingDeleteScore
        )
        .alert(
            Text("library.import.duplicate.title", bundle: .module),
            isPresented: duplicateAlertBinding,
            presenting: viewModel.duplicatePrompt
        ) { prompt in
            Button {
                viewModel.duplicatePrompt = nil
                Task { await viewModel.commit(plan: prompt.plan, decision: .openExisting(prompt.existing.id)) }
            } label: {
                L10n.Common.open
            }
            Button {
                viewModel.duplicatePrompt = nil
                Task { await viewModel.commit(plan: prompt.plan, decision: .importAsNew) }
            } label: {
                Text("library.import.duplicate.importAsDuplicate", bundle: .module)
            }
            Button(role: .cancel) {
                viewModel.duplicatePrompt = nil
            } label: {
                L10n.Common.cancel
            }
        } message: { prompt in
            Text(String(
                localized: "library.import.duplicate.message",
                defaultValue: "\"\(prompt.existing.title)\" is already imported. What do you want to do?",
                bundle: .module
            ))
        }
        .overlay {
            if viewModel.isPreparingShare {
                ProgressView { Text("library.score.preparing", bundle: .module) }
                    .padding()
                    .background(.regularMaterial, in: .rect(cornerRadius: 12))
            }
        }
        #if os(iOS)
        .sheet(item: $viewModel.shareTarget) { target in
            ActivityViewControllerRepresentable(items: target.urls)
        }
        #endif
    }

    @ToolbarContentBuilder
    private var importToolbar: some ToolbarContent {
        #if os(iOS)
            ToolbarItem(placement: .topBarTrailing) { addMenu }
        #else
            ToolbarItem(placement: .automatic) { addMenu }
        #endif
    }

    @ToolbarContentBuilder
    private var leadingToolbar: some ToolbarContent {
        #if os(iOS)
            ToolbarItem(placement: .topBarLeading) { leadingToolbarItem() }
        #else
            ToolbarItem(placement: .automatic) { leadingToolbarItem() }
        #endif
    }

    private var addMenu: some View {
        Menu {
            Button {
                viewModel.isFileImporterPresented = true
            } label: {
                Label {
                    Text("library.import.title", bundle: .module)
                } icon: {
                    Image(systemName: "square.and.arrow.down")
                }
            }
            Button {
                newPlaylistName = ""
                isCreatingPlaylist = true
            } label: {
                Label {
                    Text("library.playlist.create.title", bundle: .module)
                } icon: {
                    Image(systemName: "music.note.list")
                }
            }
            Button {
                newTagName = ""
                isCreatingTag = true
            } label: {
                Label {
                    Text("library.tag.create.title", bundle: .module)
                } icon: {
                    Image(systemName: "tag")
                }
            }
        } label: {
            Image(systemName: "plus").accessibilityLabel(L10n.Common.add)
        }
    }

    @ViewBuilder
    private var rootList: some View {
        let items = viewModel.repository.scoreItems
        let recents = items.mostRecentlyOpened(limit: 5)

        if items.isEmpty && viewModel.repository.tags.isEmpty && viewModel.repository.playlists.isEmpty {
            ContentUnavailableView {
                Label {
                    Text("library.allScores.empty.title", bundle: .module)
                } icon: {
                    Image(systemName: "music.note")
                }
            } description: {
                Text("library.allScores.empty.hint", bundle: .module)
            }
        } else {
            List {
                browseSection(items: items)
                LibraryRootPlaylistsSection(
                    allPlaylists: viewModel.repository.playlists,
                    scoreItems: items,
                    onRequestDelete: { pendingDeletePlaylist = $0 }
                )
                LibraryRootTagsSection(
                    allTags: viewModel.repository.tags,
                    scoreItems: items,
                    onRequestDelete: { pendingDeleteTag = $0 }
                )
                recentsSection(recents)
            }
            .listStyle(.sidebar)
        }
    }

    @ViewBuilder
    private func browseSection(items: [ScoreItem]) -> some View {
        let favoriteCount = items.filter(\.isFavorite).count
        Section {
            NavigationLink(value: LibraryRoute.allScores) {
                browseRow(title: "library.allScores", systemImage: "list.bullet", count: items.count)
            }
            if favoriteCount > 0 {
                NavigationLink(value: LibraryRoute.favorites) {
                    browseRow(title: "library.favorites", systemImage: "star.fill", count: favoriteCount)
                }
            }
        }
    }

    @ViewBuilder
    private func recentsSection(_ recents: [ScoreItem]) -> some View {
        if !recents.isEmpty {
            Section {
                ForEach(recents) { item in
                    sectionRow(for: item)
                }
            } header: {
                Text("library.recentlyOpened", bundle: .module)
            }
        }
    }

    @ViewBuilder
    private func sectionRow(for item: ScoreItem) -> some View {
        HStack(spacing: 0) {
            ScoreRow(scoreItem: item)
                .contentShape(Rectangle())
                .onTapGesture { onOpenScore(item) }
            Menu {
                scoreRowMenu(
                    item: item,
                    library: viewModel,
                    onOpen: onOpenScore,
                    onEditTags: { editTagsTarget = $0 },
                    onAddToPlaylist: { addToPlaylistTarget = $0 },
                    onRequestDelete: nil
                )
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 34)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.Common.more)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                Task { await viewModel.toggleFavorite(item) }
            } label: {
                Label {
                    let key: LocalizedStringKey = item.isFavorite
                        ? "library.score.unfavorite.action"
                        : "library.score.favorite.action"
                    Text(key, bundle: .module)
                } icon: {
                    Image(systemName: item.isFavorite ? "star.slash.fill" : "star.fill")
                }
            }
            .tint(.yellow)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                pendingDeleteScore = item
            } label: {
                Label {
                    L10n.Common.delete
                } icon: {
                    Image(systemName: "trash")
                }
            }
        }
        .contextMenu {
            scoreRowMenu(
                item: item,
                library: viewModel,
                onOpen: onOpenScore,
                onEditTags: { editTagsTarget = $0 },
                onAddToPlaylist: { addToPlaylistTarget = $0 },
                onRequestDelete: nil
            )
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

    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { viewModel.errorAlertMessage != nil },
            set: { isPresented in if !isPresented { viewModel.errorAlertMessage = nil } }
        )
    }

    private var duplicateAlertBinding: Binding<Bool> {
        Binding(
            get: { viewModel.duplicatePrompt != nil },
            set: { isPresented in if !isPresented { viewModel.duplicatePrompt = nil } }
        )
    }
}

enum ScoreFileTypes {
    /// Content types accepted by the import picker. Custom UTTypes are
    /// declared in `App/Info.plist`; resolving them here lets Files /
    /// Document Picker enable `.mscz` / `.mxl` / `.mscx` directly
    /// instead of dimming them as opaque `.zip` / `.xml`.
    static var allowed: [UTType] {
        let custom = [
            "org.musescore.mscx", "org.musescore.mscz",
            "com.recordare.musicxml", "com.recordare.musicxml.zipped",
        ].compactMap(UTType.init)
        return [.xml, .midi] + custom
    }
}
