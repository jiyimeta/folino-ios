import Domain
import Observation
import SwiftUI
import UtilityUI

/// The M1 "New score" form: a plain `Form` collecting the fields `NewScoreForm` maps to a `BlankScoreTemplate`.
/// Presented as a sheet from `LibraryRootPresentations`; Create hands the built form to
/// `LibraryViewModel.createScore(from:)`, which owns dismissal on success. On failure the sheet stays up (the typed
/// form isn't lost) and `currentError` is surfaced by this view's own alert — `LibraryRootPresentations`'
/// `ImportErrorAlert` is attached to the screen underneath this sheet, and SwiftUI won't present an alert from a view
/// that is already presenting a sheet, so the shared alert can't be reused here.
@MainActor
struct NewScoreSheet: View {
    let viewModel: LibraryViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var form = NewScoreForm()

    var body: some View {
        NavigationStack {
            Form {
                titleSection
                layoutSection
                lengthSection
            }
            .navigationTitle(Text("library.newScore.title", bundle: .module))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
        }
        .alert(
            Text("library.title", bundle: .module),
            isPresented: errorPresentationBinding,
            presenting: viewModel.currentError,
        ) { _ in
            Button { viewModel.currentError = nil } label: {
                L10n.Common.ok
            }
        } message: { error in
            Text(describeLibraryError(error))
        }
    }

    /// Mirrors `LibraryRootPresentations.ImportErrorAlert.presentationBinding` — same shared `currentError`, its own
    /// presentation site so the alert actually reaches the screen while this sheet covers the root.
    private var errorPresentationBinding: Binding<Bool> {
        Binding(
            get: { viewModel.currentError != nil },
            set: { isPresented in
                guard !isPresented else { return }
                viewModel.currentError = nil
            },
        )
    }

    private var titleSection: some View {
        Section {
            TextField(text: $form.title) {
                Text("library.newScore.field.title", bundle: .module)
            }
            TextField(text: $form.composer) {
                Text("library.newScore.field.composer", bundle: .module)
            }
        }
    }

    /// Preset (staff layout), key signature, and time signature — the fields that shape the blank score's layout.
    private var layoutSection: some View {
        Section {
            Picker(selection: presetIndex) {
                ForEach(Array(NewScoreForm.Preset.allCases.enumerated()), id: \.offset) { index, preset in
                    Text(Self.presetTitle(preset), bundle: .module).tag(index)
                }
            } label: {
                Text("library.newScore.field.preset", bundle: .module)
            }
            Picker(selection: $form.concertKey) {
                ForEach(NewScoreForm.keyChoices, id: \.self) { key in
                    Text(Self.keyLabel(key)).tag(key)
                }
            } label: {
                Text("library.newScore.field.key", bundle: .module)
            }
            Picker(selection: timeChoiceIndex) {
                ForEach(Array(NewScoreForm.timeChoices.enumerated()), id: \.offset) { index, choice in
                    Text(verbatim: "\(choice.0)/\(choice.1)").tag(index)
                }
            } label: {
                Text("library.newScore.field.time", bundle: .module)
            }
        }
    }

    /// Tempo and measure count — how long the blank score plays and how many bars it starts with.
    private var lengthSection: some View {
        Section {
            Stepper(value: $form.tempoBPM, in: 20 ... 300) {
                LabeledContent {
                    Text(form.tempoBPM, format: .number)
                } label: {
                    Text("library.newScore.field.tempo", bundle: .module)
                }
            }
            Stepper(value: $form.measureCount, in: 1 ... 200) {
                LabeledContent {
                    Text(form.measureCount, format: .number)
                } label: {
                    Text("library.newScore.field.measures", bundle: .module)
                }
            }
        }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button { dismiss() } label: { L10n.Common.cancel }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button {
                Task { await viewModel.createScore(from: form) }
            } label: {
                Text("library.newScore.create", bundle: .module)
            }
            .disabled(form.template() == nil)
        }
    }

    /// `Preset` is intentionally not `Hashable` (only `CaseIterable`/`Equatable`, per its Domain-visible shape), so the
    /// picker binds by index into `Preset.allCases` rather than by the case itself.
    private var presetIndex: Binding<Int> {
        Binding(
            get: { Array(NewScoreForm.Preset.allCases).firstIndex(of: form.preset) ?? 0 },
            set: { newIndex in
                let cases = Array(NewScoreForm.Preset.allCases)
                guard cases.indices.contains(newIndex) else { return }
                form.preset = cases[newIndex]
            },
        )
    }

    /// `(Int, Int)` tuples aren't `Hashable`, so the time-signature picker binds by index into `timeChoices` and
    /// writes both `timeNumerator`/`timeDenominator` back on selection.
    private var timeChoiceIndex: Binding<Int> {
        Binding(
            get: {
                NewScoreForm.timeChoices.firstIndex { $0.0 == form.timeNumerator && $0.1 == form.timeDenominator } ?? 0
            },
            set: { newIndex in
                guard NewScoreForm.timeChoices.indices.contains(newIndex) else { return }
                let choice = NewScoreForm.timeChoices[newIndex]
                form.timeNumerator = choice.0
                form.timeDenominator = choice.1
            },
        )
    }

    private static func presetTitle(_ preset: NewScoreForm.Preset) -> LocalizedStringKey {
        switch preset {
        case .piano: "library.newScore.preset.piano"
        case .trebleStaff: "library.newScore.preset.treble"
        case .bassStaff: "library.newScore.preset.bass"
        }
    }

    /// Key names are universal note-letter spellings, not prose — written out once here rather than through the
    /// localization catalog. Circle of fifths, C-major center, matching `NewScoreForm.keyChoices`' order.
    private static func keyLabel(_ concertKey: Int) -> String {
        switch concertKey {
        case 0: "C / Am"
        case 1: "G / Em"
        case 2: "D / Bm"
        case 3: "A / F♯m"
        case 4: "E / C♯m"
        case 5: "B / G♯m"
        case 6: "F♯ / D♯m"
        case -1: "F / Dm"
        case -2: "B♭ / Gm"
        case -3: "E♭ / Cm"
        case -4: "A♭ / Fm"
        case -5: "D♭ / B♭m"
        case -6: "G♭ / E♭m"
        default: "\(concertKey)"
        }
    }
}

#if DEBUG
/// Minimal in-memory doubles so the preview is self-contained (no App composition root needed). None of these are
/// exercised by rendering the sheet — `NewScoreSheet` only calls into `viewModel.createScore(from:)` when Create is
/// tapped, which a preview never drives — so every method is a stub.
@MainActor
@Observable
private final class PreviewScoreLibraryRepository: ScoreLibraryRepository {
    var scoreItems: [ScoreItem] = []
    var deletedScoreItems: [ScoreItem] = []
    var tags: [Tag] = []
    var playlists: [Playlist] = []

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

private struct PreviewScoreOriginalStore: ScoreOriginalStore {
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

private struct PreviewScoreFileImporter: ScoreFileImporter {
    func prepareImport(sourceURL _: URL) throws -> ImportPlan {
        throw DomainError.unsupportedFormat("preview")
    }

    func commitImport(_: ImportPlan, decision _: ImportDecision) throws -> ScoreItem {
        throw DomainError.unsupportedFormat("preview")
    }
}

private struct PreviewScoreFileGateway: ScoreFileGateway {
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

private struct PreviewScoreShareService: ScoreShareService {
    func availableFormats(for _: ScoreItem) -> [ScoreShareFormatOption] {
        []
    }

    func prepareShare(item _: ScoreItem, format: ScoreShareFormat) throws -> URL {
        throw DomainError.unsupportedFormat(format.canonicalExtension)
    }
}

private struct PreviewScoreMetadataReading: ScoreMetadataReading {
    func readMetadata(for _: ScoreItem) throws -> ScoreFileMetadata {
        throw DomainError.unsupportedFormat("preview")
    }
}

private struct PreviewScoreFileCreator: ScoreFileCreator {
    func createScore(_: Score) throws -> ScoreItem {
        throw DomainError.unsupportedFormat("preview")
    }
}

#Preview {
    NewScoreSheet(viewModel: LibraryViewModel(
        repository: PreviewScoreLibraryRepository(),
        originalStore: PreviewScoreOriginalStore(),
        importer: PreviewScoreFileImporter(),
        gateway: PreviewScoreFileGateway(),
        shareService: PreviewScoreShareService(),
        metadataReader: PreviewScoreMetadataReading(),
        creator: PreviewScoreFileCreator(),
    ))
}
#endif
