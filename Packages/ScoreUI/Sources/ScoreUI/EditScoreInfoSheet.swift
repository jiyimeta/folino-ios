import Domain
import SwiftUI
import UtilityUI

/// Modal metadata editor for a single score. Editable credit fields (top section) plus a read-only info section
/// (source format + date added). Title is required; Save is disabled while it is blank. On appear the on-disk file is
/// parsed once to fill the source label and pre-fill any never-edited credit field.
@MainActor
public struct EditScoreInfoSheet: View {
    let model: any ScoreInfoEditing
    let item: ScoreItem
    @Environment(\.dismiss) private var dismiss

    @State private var fields: EditableScoreInfo
    /// The field values the sheet opened with (after file pre-fill). Compared against `fields` to detect unsaved edits.
    @State private var baseline: EditableScoreInfo
    @State private var sourceKind: ScoreSourceKind?
    @State private var didLoad = false
    @State private var showDiscardConfirmation = false

    public init(model: any ScoreInfoEditing, item: ScoreItem) {
        self.model = model
        self.item = item
        let initial = EditableScoreInfo(item: item, fileMetadata: nil)
        _fields = State(initialValue: initial)
        _baseline = State(initialValue: initial)
    }

    private var trimmedTitle: String {
        fields.title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasChanges: Bool {
        fields != baseline
    }

    public var body: some View {
        NavigationStack {
            Form {
                creditsSection
                infoSection
                if RevertToOriginalSection.shouldShow(item) {
                    RevertToOriginalSection(model: model, item: item) { dismiss() }
                }
            }
            .navigationTitle(Text("scoreUI.editInfo.title", bundle: .module))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .task { await loadOnce() }
            .interactiveDismissDisabled(hasChanges)
            .alert(
                Text("scoreUI.editInfo.discardAlert.title", bundle: .module),
                isPresented: $showDiscardConfirmation,
            ) {
                Button(role: .cancel) {} label: {
                    Text("scoreUI.editInfo.discardAlert.keepEditing", bundle: .module)
                }
                Button(role: .destructive) { dismiss() } label: {
                    Text("scoreUI.editInfo.discardAlert.discard", bundle: .module)
                }
            }
        }
    }

    /// Gray hint shown in any empty editable field. The field's own label already names it, so the placeholder only
    /// signals "no value yet — tap to set" rather than repeating the field name.
    private var unsetPlaceholder: String {
        String(localized: "scoreUI.field.unsetPlaceholder", bundle: .module)
    }

    private var creditsSection: some View {
        Section {
            LabeledContent {
                TextField(unsetPlaceholder, text: $fields.title).singleLineEditFieldStyle()
            } label: {
                Text("scoreUI.field.title", bundle: .module)
            }
            LabeledContent {
                TextField(unsetPlaceholder, text: $fields.subtitle).singleLineEditFieldStyle()
            } label: {
                Text("scoreUI.field.subtitle", bundle: .module)
            }
            LabeledContent {
                TextField(unsetPlaceholder, text: $fields.composer).singleLineEditFieldStyle()
            } label: {
                Text("scoreUI.field.composer", bundle: .module)
            }
            LabeledContent {
                TextField(unsetPlaceholder, text: $fields.arranger).singleLineEditFieldStyle()
            } label: {
                Text("scoreUI.field.arranger", bundle: .module)
            }
            LabeledContent {
                TextField(unsetPlaceholder, text: $fields.lyricist).singleLineEditFieldStyle()
            } label: {
                Text("scoreUI.field.lyricist", bundle: .module)
            }
            LabeledContent {
                TextField(unsetPlaceholder, text: $fields.copyright, axis: .vertical).editFieldStyle()
            } label: {
                Text("scoreUI.field.copyright", bundle: .module)
            }
        }
    }

    private var infoSection: some View {
        Section {
            LabeledContent {
                Text(Self.sourceLabel(sourceKind))
            } label: {
                Text("scoreUI.field.source", bundle: .module)
            }
            LabeledContent {
                Text(item.addedAt, format: .dateTime.year().month().day().hour().minute())
            } label: {
                Text("scoreUI.field.dateAdded", bundle: .module)
            }
        } header: {
            Text("scoreUI.info.section", bundle: .module)
        }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button {
                if hasChanges {
                    showDiscardConfirmation = true
                } else {
                    dismiss()
                }
            } label: {
                SheetActionLabel(.close, title: L10n.Common.cancel)
            }
        }
        ToolbarItem(placement: .confirmationAction) {
            SheetConfirmButton(title: L10n.Common.save) {
                let snapshot = fields
                Task {
                    await model.saveMetadata(item, fields: snapshot)
                    dismiss()
                }
            }
            .disabled(trimmedTitle.isEmpty)
        }
    }

    private func loadOnce() async {
        guard !didLoad else { return }
        didLoad = true
        let meta = await model.loadFileMetadata(for: item)
        sourceKind = meta?.source
        let prefilled = EditableScoreInfo(item: item, fileMetadata: meta)
        fields = prefilled
        baseline = prefilled
    }

    /// Human-readable source label. MuseScore/MusicXML/MIDI/PDF are brand/format literals (identical across locales);
    /// only "Unknown" / a missing parse is localized.
    static func sourceLabel(_ kind: ScoreSourceKind?) -> String {
        // Brand/format literals come from the shared `ScoreSourceKind.displayLabel` (also used by Android); only the
        // empty (unknown / missing parse) case is localized here.
        let label = kind?.displayLabel ?? ""
        return label.isEmpty ? String(localized: "scoreUI.source.unknown", bundle: .module) : label
    }
}

extension View {
    /// Right-aligns an editable field's text so its content sits at the trailing edge of the row, matching the
    /// read-only values in the info section.
    fileprivate func editFieldStyle() -> some View {
        multilineTextAlignment(.trailing)
    }

    /// `editFieldStyle()` plus a "Done" return key — the confirm-style key for single-line fields (iOS has no
    /// checkmark return key, so `.done` is the closest "commit and dismiss the keyboard" affordance).
    fileprivate func singleLineEditFieldStyle() -> some View {
        editFieldStyle().submitLabel(.done)
    }
}

#if DEBUG
/// Minimal in-memory `ScoreInfoEditing` double so the preview is self-contained (no feature view model needed).
private struct PreviewInfoEditing: ScoreInfoEditing {
    // swiftlint:disable:next async_without_await
    func loadFileMetadata(for _: ScoreItem) async -> ScoreFileMetadata? {
        ScoreFileMetadata(
            source: .museScore(majorVersion: 4),
            composer: "From File", arranger: nil, lyricist: nil, copyright: "© 2026",
        )
    }

    // swiftlint:disable:next async_without_await
    func saveMetadata(_: ScoreItem, fields _: EditableScoreInfo) async {}

    // swiftlint:disable:next async_without_await
    func revertToOriginal(_: ScoreItem, restoringScoreInfo _: Bool) async {}
}

#Preview {
    EditScoreInfoSheet(
        model: PreviewInfoEditing(),
        item: ScoreItem(
            title: "Clair de Lune", subtitle: "Suite bergamasque",
            composer: nil, arranger: nil, lyricist: nil, copyright: nil,
            instrumentationSummary: "Piano",
            localFileName: "\(UUID().uuidString).mscz",
            contentHash: String(repeating: "0", count: 64),
            sizeBytes: 4096, lengthBeats: 256, defaultTempoBpm: 66, primaryKey: nil,
            addedAt: Date(timeIntervalSince1970: 1_700_000_000), lastOpenedAt: nil,
            tagIDs: [], isFavorite: false,
        ),
    )
}

#Preview("With an original to revert to") {
    var item = ScoreItem(
        title: "Clair de Lune", subtitle: "Suite bergamasque",
        composer: nil, arranger: nil, lyricist: nil, copyright: nil,
        instrumentationSummary: "Piano",
        localFileName: "\(UUID().uuidString).mscz",
        contentHash: String(repeating: "0", count: 64),
        sizeBytes: 4096, lengthBeats: 256, defaultTempoBpm: 66, primaryKey: nil,
        addedAt: Date(timeIntervalSince1970: 1_700_000_000), lastOpenedAt: nil,
        tagIDs: [], isFavorite: false,
    )
    item.originalFileName = "\(UUID().uuidString).original.mscz"
    item.originalProvenance = .importTime
    return EditScoreInfoSheet(model: PreviewInfoEditing(), item: item)
}
#endif
