import Domain
import SwiftUI
import UtilityUI

/// Modal metadata editor for a single score. Editable credit fields (top section) plus a read-only info section
/// (source format + date added). Title is required; Save is disabled while it is blank. On appear the on-disk file is
/// parsed once to fill the source label and pre-fill any never-edited credit field.
@MainActor
struct EditScoreInfoSheet: View {
    let viewModel: LibraryViewModel
    let item: ScoreItem
    @Environment(\.dismiss) private var dismiss

    @State private var fields: EditableScoreInfo
    @State private var sourceKind: ScoreSourceKind?
    @State private var didLoad = false

    init(viewModel: LibraryViewModel, item: ScoreItem) {
        self.viewModel = viewModel
        self.item = item
        _fields = State(initialValue: EditableScoreInfo(item: item, fileMetadata: nil))
    }

    private var trimmedTitle: String {
        fields.title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                creditsSection
                infoSection
            }
            .navigationTitle(Text("library.score.editInfo.title", bundle: .module))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .task { await loadOnce() }
        }
    }

    private var creditsSection: some View {
        Section {
            LabeledContent { TextField("", text: $fields.title) } label: {
                Text("library.score.field.title", bundle: .module)
            }
            LabeledContent { TextField("", text: $fields.subtitle) } label: {
                Text("library.score.field.subtitle", bundle: .module)
            }
            LabeledContent { TextField("", text: $fields.composer) } label: {
                Text("library.score.field.composer", bundle: .module)
            }
            LabeledContent { TextField("", text: $fields.arranger) } label: {
                Text("library.score.field.arranger", bundle: .module)
            }
            LabeledContent { TextField("", text: $fields.lyricist) } label: {
                Text("library.score.field.lyricist", bundle: .module)
            }
            LabeledContent { TextField("", text: $fields.copyright, axis: .vertical) } label: {
                Text("library.score.field.copyright", bundle: .module)
            }
        }
    }

    private var infoSection: some View {
        Section {
            LabeledContent {
                Text(Self.sourceLabel(sourceKind))
            } label: {
                Text("library.score.field.source", bundle: .module)
            }
            LabeledContent {
                Text(item.addedAt, format: .dateTime.year().month().day().hour().minute())
            } label: {
                Text("library.score.field.dateAdded", bundle: .module)
            }
        } header: {
            Text("library.score.info.section", bundle: .module)
        }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button { dismiss() } label: { L10n.Common.cancel }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button {
                let snapshot = fields
                Task {
                    await viewModel.saveMetadata(item, fields: snapshot)
                    dismiss()
                }
            } label: { L10n.Common.save }
                .disabled(trimmedTitle.isEmpty)
        }
    }

    private func loadOnce() async {
        guard !didLoad else { return }
        didLoad = true
        let meta = await viewModel.loadFileMetadata(for: item)
        sourceKind = meta?.source
        fields = EditableScoreInfo(item: item, fileMetadata: meta)
    }

    /// Human-readable source label. MuseScore/MusicXML/MIDI/PDF are brand/format literals (identical across locales);
    /// only "Unknown" / a missing parse is localized.
    static func sourceLabel(_ kind: ScoreSourceKind?) -> String {
        switch kind {
        case let .museScore(major): "MuseScore \(major)"
        case .musicXML: "MusicXML"
        case .midi: "MIDI"
        case .pdf: "PDF"
        case .unknown, nil:
            String(localized: "library.score.source.unknown", bundle: .module)
        }
    }
}

#if DEBUG
/// Minimal no-op Domain doubles so the preview can construct a `LibraryViewModel`. They are not exercised by the
/// preview's interaction path — the sheet only calls `loadFileMetadata` (served by the metadata reader) and
/// `saveMetadata`. Kept inline because the Tests target's fakes are not importable from Sources.
private enum EditScoreInfoSheetPreview {
    @MainActor @Observable
    final class Repository: ScoreLibraryRepository {
        var scoreItems: [ScoreItem] = []
        var deletedScoreItems: [ScoreItem] = []
        var tags: [Tag] = []
        var playlists: [Playlist] = []
        func refresh() throws {}
        func saveScoreItem(_: ScoreItem) throws {}
        func deleteScoreItem(id _: ScoreItemID) throws {}
        func softDeleteScoreItem(id _: ScoreItemID) throws {}
        func restoreScoreItem(id _: ScoreItemID) throws {}
        func permanentlyDeleteScoreItem(id _: ScoreItemID) throws {}
        func pruneScoreItemsDeleted(before _: Date) throws {}
        func saveTag(_: Tag) throws {}
        func deleteTag(id _: TagID) throws {}
        func savePlaylist(_: Playlist) throws {}
        func deletePlaylist(id _: PlaylistID) throws {}
        func scoreItems(matchingContentHash _: String) throws -> [ScoreItem] {
            []
        }

        func loadReaderPreferences(for _: ScoreItemID) throws -> ReaderPreferences? {
            nil
        }

        func saveReaderPreferences(_: ReaderPreferences) throws {}
    }

    struct Importer: ScoreFileImporter {
        func prepareImport(sourceURL: URL) throws -> ImportPlan {
            throw DomainError.unsupportedFormat("preview")
        }

        func commitImport(_: ImportPlan, decision _: ImportDecision) throws -> ScoreItem {
            throw DomainError.unsupportedFormat("preview")
        }
    }

    struct Gateway: ScoreFileGateway {
        func detectFormat(fileName _: String) -> ScoreFormat? {
            nil
        }

        func loadFileMetadata(fileURL _: URL) throws -> ScoreFileSummary {
            throw DomainError.unsupportedFormat("preview")
        }

        func loadScore(fileURL _: URL) throws -> (score: Score, summary: ScoreFileSummary) {
            throw DomainError.unsupportedFormat("preview")
        }

        func saveScore(_: Score, fileURL _: URL, format _: ScoreFormat) throws {
            throw DomainError.unsupportedFormat("preview")
        }
    }

    struct ShareService: ScoreShareService {
        func availableFormats(for _: ScoreItem) -> [ScoreShareFormatOption] {
            []
        }

        func prepareShare(item _: ScoreItem, format _: ScoreShareFormat) throws -> URL {
            throw DomainError.unsupportedFormat("preview")
        }
    }

    struct MetadataReader: ScoreMetadataReading {
        func readMetadata(for _: ScoreItem) throws -> ScoreFileMetadata {
            ScoreFileMetadata(
                source: .museScore(majorVersion: 4),
                composer: "From File",
                arranger: nil,
                lyricist: nil,
                copyright: "© 2026",
            )
        }
    }

    @MainActor static func viewModel() -> LibraryViewModel {
        LibraryViewModel(
            repository: Repository(),
            importer: Importer(),
            gateway: Gateway(),
            shareService: ShareService(),
            metadataReader: MetadataReader(),
        )
    }

    static let item = ScoreItem(
        title: "Clair de Lune",
        subtitle: "Suite bergamasque",
        composer: nil,
        arranger: nil,
        lyricist: nil,
        copyright: nil,
        instrumentationSummary: "Piano",
        localFileName: "\(UUID().uuidString).mscz",
        contentHash: String(repeating: "0", count: 64),
        sizeBytes: 4096,
        lengthBeats: 256,
        defaultTempoBpm: 66,
        primaryKey: nil,
        addedAt: Date(timeIntervalSince1970: 1_700_000_000),
        lastOpenedAt: nil,
        tagIDs: [],
        isFavorite: false,
    )
}

#Preview {
    EditScoreInfoSheet(
        viewModel: EditScoreInfoSheetPreview.viewModel(),
        item: EditScoreInfoSheetPreview.item,
    )
}
#endif
