# Reader score-info & share buttons (shared `ScoreUI` module) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a 2+2 grouped-pill top-right toolbar to the Reader — a new "this score" pill (score-info + share) beside the existing settings pill — reusing Library's share menu and edit-info sheet by lifting them into a new shared `ScoreUI` module.

**Architecture:** Introduce `Packages/ScoreUI/` (depends on Domain + UtilityUI, depended on by Feature packages) to host SwiftUI components that need Domain types but must be shared across Features without violating `Feature → Feature`. Move `ShareSubmenu`, `EditScoreInfoSheet`, and `EditableScoreInfo` there, decoupling the sheet from `LibraryViewModel` via a new `@MainActor protocol ScoreInfoEditing`. Library and Reader both consume `ScoreUI`; export logic (`ScoreShareService`) is reused unchanged.

**Tech Stack:** Swift 6.3, SwiftUI, SwiftPM local packages, XcodeGen, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-06-01-reader-score-info-and-share-design.md`

**Conventions used throughout this plan:**
- Per-package build/test (fast loop), run from the package directory:
  `xcodebuild build -scheme <PackageName> -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation`
  `xcodebuild test  -scheme <PackageName> -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation`
  (`swift test` is broken by the SwiftLint plugin's macOS requirement — do not use it. The iPhone 16 simulator is not installed; use iPhone 17.)
- Whole-app build (final gate), run from repo root:
  `xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation build`
- After editing `project.yml`: `xcodegen generate` from repo root.
- Stage whole files only (no `git add -p`). The pre-commit hook reformats staged Swift and fails until clean — re-stage and re-commit if it rewrites files.
- Commit messages end with the Co-Authored-By trailer used elsewhere in this repo.

---

## File Structure

**New package `Packages/ScoreUI/`:**
- `Package.swift` — package manifest (Domain + UtilityUI deps).
- `Sources/ScoreUI/EditableScoreInfo.swift` — `public struct EditableScoreInfo` + the `init(item:fileMetadata:)` pre-fill (moved from Library).
- `Sources/ScoreUI/ScoreInfoEditing.swift` — `public protocol ScoreInfoEditing`.
- `Sources/ScoreUI/ScoreShareTarget.swift` — `public struct ScoreShareTarget`.
- `Sources/ScoreUI/EditScoreInfoSheet.swift` — `public struct EditScoreInfoSheet` (moved, decoupled from `LibraryViewModel`).
- `Sources/ScoreUI/ShareSubmenu.swift` — `public struct ShareSubmenu` + format label/icon helpers (moved).
- `Sources/ScoreUI/Resources/Localizable.xcstrings` — strings moved out of Library, re-keyed `scoreUI.*`.
- `Tests/ScoreUITests/EditableScoreInfoTests.swift` — pre-fill unit tests.

**Reader (`Packages/Features/Reader/`):**
- `Package.swift` — add `ScoreUI` dependency.
- `Sources/Reader/ReaderViewModel.swift` — add `shareService` + `metadataReader`, share state, `requestShare`, `ScoreInfoEditing` conformance.
- `Sources/Reader/NoopScoreServices.swift` — internal no-op defaults so previews/tests need no new args.
- `Sources/Reader/Screens/ReaderToolbar.swift` — new "this score" pill + sheet/menu presentation.
- `Sources/Reader/Screens/ReaderRootScreen.swift` — thread `shareService` + `metadataReader` through init.
- `Sources/Reader/Resources/*.xcstrings` — add `reader.toolbar.showInfo`, `reader.toolbar.share`.
- `Tests/ReaderTests/Fakes/FakeScoreShareService.swift`, `Fakes/FakeScoreMetadataReading.swift` — new fakes.
- `Tests/ReaderTests/ReaderViewModelShareTests.swift`, `ReaderViewModelInfoEditingTests.swift` — new tests.

**Library (`Packages/Features/Library/`):**
- `Package.swift` — add `ScoreUI` dependency.
- Delete `Sources/Library/Views/EditScoreInfoSheet.swift`, `Views/EditableScoreInfo+PreFill.swift`; remove `EditableScoreInfo` struct + `ShareSubmenu` (+ helpers) from their current files.
- `Sources/Library/LibraryViewModel.swift` — remove `EditableScoreInfo`/`ShareTarget`, add `ScoreInfoEditing` conformance, adopt `ScoreShareTarget`.
- Update call sites: `EditScoreInfoSheetModifier.swift`, `ScoreRowMenu.swift`, screens.
- Library `.xcstrings` — remove the moved keys.

**App:**
- `App/AppShellView.swift` — pass `shareService` + `metadataReader` into the 3 `ReaderRootScreen(...)` call sites.

**Docs:**
- `docs/engineering/module-architecture.md` — add the `ScoreUI` layer.
- `project.yml` — register the `ScoreUI` package.

---

## Task 1: Create `ScoreUI` package with shared value types

**Files:**
- Create: `Packages/ScoreUI/Package.swift`
- Create: `Packages/ScoreUI/Sources/ScoreUI/EditableScoreInfo.swift`
- Create: `Packages/ScoreUI/Sources/ScoreUI/ScoreInfoEditing.swift`
- Create: `Packages/ScoreUI/Sources/ScoreUI/ScoreShareTarget.swift`
- Create: `Packages/ScoreUI/Tests/ScoreUITests/EditableScoreInfoTests.swift`
- Modify: `project.yml:26-42` (packages block)

- [ ] **Step 1: Write `Package.swift`**

`Packages/ScoreUI/Package.swift`:

```swift
// swift-tools-version: 6.3
import PackageDescription

let swiftLintPlugins: [Target.PluginUsage] = [
    .plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins"),
]

let package = Package(
    name: "ScoreUI",
    defaultLocalization: "en",
    platforms: [.iOS(.v26)],
    products: [
        .library(name: "ScoreUI", targets: ["ScoreUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/SimplyDanny/SwiftLintPlugins", from: "0.63.2"),
        .package(path: "../Domain"),
        .package(path: "../Utility"),
    ],
    targets: [
        .target(
            name: "ScoreUI",
            dependencies: [
                "Domain",
                .product(name: "UtilityCore", package: "Utility"),
                .product(name: "UtilityUI", package: "Utility"),
            ],
            resources: [.process("Resources")],
            plugins: swiftLintPlugins,
        ),
        .testTarget(name: "ScoreUITests", dependencies: ["ScoreUI"]),
    ],
)
```

- [ ] **Step 2: Move `EditableScoreInfo` (struct + pre-fill init) into ScoreUI, made public**

`Packages/ScoreUI/Sources/ScoreUI/EditableScoreInfo.swift` — copy the struct from `Library/LibraryViewModel.swift:7-14` and the init from `Library/Views/EditableScoreInfo+PreFill.swift`, making both `public`:

```swift
import Domain

/// Mutable form payload for the edit-info sheet. Empty strings are meaningful — saving an empty field clears it
/// (persisted as `""`, which suppresses future file pre-fill).
public struct EditableScoreInfo: Equatable {
    public var title: String
    public var subtitle: String
    public var composer: String
    public var arranger: String
    public var lyricist: String
    public var copyright: String

    public init(
        title: String,
        subtitle: String,
        composer: String,
        arranger: String,
        lyricist: String,
        copyright: String,
    ) {
        self.title = title
        self.subtitle = subtitle
        self.composer = composer
        self.arranger = arranger
        self.lyricist = lyricist
        self.copyright = copyright
    }

    /// Build the sheet's initial field values. For each optional credit field: a stored value (including an explicit
    /// empty string the user previously saved) wins; only a NULL column falls back to the file's metaTag. Subtitle is
    /// not a metaTag, so it comes straight from the stored value.
    public init(item: ScoreItem, fileMetadata: ScoreFileMetadata?) {
        self.init(
            title: item.title,
            subtitle: item.subtitle ?? "",
            composer: item.composer ?? fileMetadata?.composer ?? "",
            arranger: item.arranger ?? fileMetadata?.arranger ?? "",
            lyricist: item.lyricist ?? fileMetadata?.lyricist ?? "",
            copyright: item.copyright ?? fileMetadata?.copyright ?? "",
        )
    }
}
```

- [ ] **Step 3: Define `ScoreInfoEditing`**

`Packages/ScoreUI/Sources/ScoreUI/ScoreInfoEditing.swift`:

```swift
import Domain

/// Abstraction the edit-info sheet uses instead of a concrete feature view model. Library and Reader view models both
/// conform, supplying the file-metadata read (for credit pre-fill) and the persist step.
@MainActor
public protocol ScoreInfoEditing {
    /// On-disk credit metaTags for pre-fill. Returns nil if the file can't be parsed (editing still proceeds).
    func loadFileMetadata(for item: ScoreItem) async -> ScoreFileMetadata?
    /// Apply edited fields and persist. Title is required (trimmed, non-empty); empties are stored as `""`.
    func saveMetadata(_ item: ScoreItem, fields: EditableScoreInfo) async
}
```

- [ ] **Step 4: Define `ScoreShareTarget`**

`Packages/ScoreUI/Sources/ScoreUI/ScoreShareTarget.swift`:

```swift
import Foundation

/// Identifiable payload that drives a share-sheet presentation. Replaces the per-view-model `ShareTarget` so Library
/// and Reader present `ActivityViewControllerRepresentable` with one shared type.
public struct ScoreShareTarget: Identifiable, Equatable {
    public let id: UUID
    public let urls: [URL]
    public init(urls: [URL]) {
        id = UUID()
        self.urls = urls
    }
}
```

- [ ] **Step 5: Register the package in `project.yml`**

In `project.yml`, under `packages:` (after the `Infrastructure:` entry, before `Library:`), add:

```yaml
  ScoreUI:
    path: Packages/ScoreUI
```

- [ ] **Step 6: Write the pre-fill unit test**

`Packages/ScoreUI/Tests/ScoreUITests/EditableScoreInfoTests.swift`:

```swift
import Domain
import Foundation
@testable import ScoreUI
import Testing

@Suite struct EditableScoreInfoTests {
    private func makeItem(
        composer: String? = nil,
        arranger: String? = nil,
        subtitle: String? = nil,
    ) -> ScoreItem {
        ScoreItem(
            title: "Title", subtitle: subtitle, composer: composer, arranger: arranger,
            lyricist: nil, copyright: nil, instrumentationSummary: nil,
            localFileName: "x.mscz", contentHash: String(repeating: "0", count: 64),
            sizeBytes: 0, lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: Date(timeIntervalSince1970: 0), lastOpenedAt: nil,
            tagIDs: [], isFavorite: false,
        )
    }

    private func meta(composer: String?) -> ScoreFileMetadata {
        ScoreFileMetadata(
            source: .museScore(majorVersion: 4),
            composer: composer, arranger: nil, lyricist: nil, copyright: nil,
        )
    }

    @Test func `stored composer wins over file metadata`() {
        let fields = EditableScoreInfo(item: makeItem(composer: "Stored"), fileMetadata: meta(composer: "File"))
        #expect(fields.composer == "Stored")
    }

    @Test func `nil stored field falls back to file metadata`() {
        let fields = EditableScoreInfo(item: makeItem(composer: nil), fileMetadata: meta(composer: "File"))
        #expect(fields.composer == "File")
    }

    @Test func `both nil yields empty string`() {
        let fields = EditableScoreInfo(item: makeItem(composer: nil), fileMetadata: meta(composer: nil))
        #expect(fields.composer == "")
    }

    @Test func `subtitle comes straight from stored value, never file metadata`() {
        let fields = EditableScoreInfo(item: makeItem(subtitle: "Sub"), fileMetadata: meta(composer: "File"))
        #expect(fields.subtitle == "Sub")
    }
}
```

- [ ] **Step 7: Build & test ScoreUI**

Run (from `Packages/ScoreUI/`): `xcodebuild test -scheme ScoreUI -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation`
Expected: builds; all 4 `EditableScoreInfoTests` pass.

- [ ] **Step 8: Commit**

```bash
git add Packages/ScoreUI project.yml
git commit -m "feat(scoreui): add ScoreUI package with shared score-info value types"
```

---

## Task 2: Move `ShareSubmenu` (+ format helpers) into ScoreUI

**Files:**
- Create: `Packages/ScoreUI/Sources/ScoreUI/ShareSubmenu.swift`
- Create: `Packages/ScoreUI/Sources/ScoreUI/Resources/Localizable.xcstrings`
- Modify: `Packages/Features/Library/Sources/Library/Views/ScoreRowMenu.swift:71-166` (remove moved code)

- [ ] **Step 1: Create `ShareSubmenu.swift` in ScoreUI**

Move the `ShareSubmenu` struct and the four `shareMenu*` helpers from `Library/Views/ScoreRowMenu.swift:71-166`. Make `ShareSubmenu` and its initializer-relevant members `public`, and re-key the localized strings from `library.format.*` to `scoreUI.format.*`. Full file:

```swift
import Domain
import SwiftUI
import UtilityUI

/// Lazy-loading share submenu. Shows the placeholder formats (no `isOriginal` flag) until the menu first opens, then
/// fetches the per-item options once via `loadFormats` and updates the rows in place. Loading on first open avoids
/// parsing every score in a large list at row-appear time.
@MainActor
public struct ShareSubmenu: View {
    let loadFormats: @Sendable () async -> [ScoreShareFormatOption]
    let onShare: (ScoreShareFormat) -> Void

    @State private var options: [ScoreShareFormatOption] = ShareSubmenu.placeholderFormats
    @State private var hasLoaded = false

    public init(
        loadFormats: @escaping @Sendable () async -> [ScoreShareFormatOption],
        onShare: @escaping (ScoreShareFormat) -> Void,
    ) {
        self.loadFormats = loadFormats
        self.onShare = onShare
    }

    public var body: some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button {
                    onShare(option.format)
                } label: {
                    shareMenuLabel(option: option)
                }
            }
            // Triggers exactly when the menu opens. The empty view disappears when the menu closes, cancelling the task
            // — the `hasLoaded` flag stops the next open from refetching.
            Color.clear.frame(width: 0, height: 0)
                .task {
                    guard !hasLoaded else { return }
                    options = await loadFormats()
                    hasLoaded = true
                }
        } label: {
            Label {
                L10n.Common.share
            } icon: {
                Image(systemName: "square.and.arrow.up")
            }
        }
    }

    static let placeholderFormats: [ScoreShareFormatOption] = [
        ScoreShareFormatOption(format: .museScoreV4),
        ScoreShareFormatOption(format: .museScoreV3),
        ScoreShareFormatOption(format: .pdf),
        ScoreShareFormatOption(format: .midi),
        ScoreShareFormatOption(format: .audioM4A),
    ]
}

@MainActor
private func shareMenuLabel(option: ScoreShareFormatOption) -> some View {
    Label {
        shareMenuTitle(for: option)
    } icon: {
        Image(systemName: shareMenuIconName(for: option.format))
    }
}

@MainActor
@ViewBuilder
private func shareMenuTitle(for option: ScoreShareFormatOption) -> some View {
    let formatText = shareMenuFormatText(for: option.format)
    if option.isOriginal {
        // Mark the option that matches the source's format so the user can tell it from re-encoded peers.
        formatText
            + Text(verbatim: " ")
            + Text("scoreUI.format.original.suffix", bundle: .module)
    } else {
        formatText
    }
}

private func shareMenuFormatText(for format: ScoreShareFormat) -> Text {
    switch format {
    case .museScoreV4:
        Text("scoreUI.format.musescore4", bundle: .module)
    case .museScoreV3:
        Text("scoreUI.format.musescore3", bundle: .module)
    case .pdf:
        Text("scoreUI.format.pdf", bundle: .module)
    case .midi:
        Text("scoreUI.format.midi", bundle: .module)
    case .audioM4A:
        Text("scoreUI.format.m4a", bundle: .module)
    }
}

private func shareMenuIconName(for format: ScoreShareFormat) -> String {
    switch format {
    case .museScoreV4, .museScoreV3:
        "doc.zipper"
    case .pdf:
        "doc.richtext"
    case .midi:
        "pianokeys"
    case .audioM4A:
        "waveform"
    }
}
```

- [ ] **Step 2: Create ScoreUI's string catalog with the format keys**

Create `Packages/ScoreUI/Sources/ScoreUI/Resources/Localizable.xcstrings`. Open `Packages/Features/Library/Sources/Library/Resources/<the .xcstrings file>` and copy the entries for these keys, renaming the key prefix `library.format.` → `scoreUI.format.`:

| Old key (Library) | New key (ScoreUI) |
| --- | --- |
| `library.format.original.suffix` | `scoreUI.format.original.suffix` |
| `library.format.musescore4` | `scoreUI.format.musescore4` |
| `library.format.musescore3` | `scoreUI.format.musescore3` |
| `library.format.pdf` | `scoreUI.format.pdf` |
| `library.format.midi` | `scoreUI.format.midi` |
| `library.format.m4a` | `scoreUI.format.m4a` |

Preserve each entry's existing localizations verbatim — only the key string changes. Use a minimal valid `.xcstrings` envelope (`"sourceLanguage" : "en"`, `"version" : "1.0"`, `"strings" : { … }`).

- [ ] **Step 3: Remove the moved code from Library's `ScoreRowMenu.swift`**

In `Packages/Features/Library/Sources/Library/Views/ScoreRowMenu.swift`, delete lines `71-166` (the `ShareSubmenu` struct and all four `shareMenu*` helpers). Keep the `scoreRowMenu(...)` builder (lines 1-69) intact — it still references `ShareSubmenu(...)` at line 57, which will resolve via the new `import ScoreUI` added in Task 4. (Library does not compile in isolation until Task 4 adds the dependency; that is expected and handled there.)

- [ ] **Step 4: Build ScoreUI**

Run (from `Packages/ScoreUI/`): `xcodebuild build -scheme ScoreUI -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation`
Expected: builds clean (Library is not built in this step).

- [ ] **Step 5: Commit**

```bash
git add Packages/ScoreUI Packages/Features/Library/Sources/Library/Views/ScoreRowMenu.swift
git commit -m "feat(scoreui): move ShareSubmenu into ScoreUI, re-key format strings"
```

---

## Task 3: Move `EditScoreInfoSheet` into ScoreUI, decoupled from the view model

**Files:**
- Create: `Packages/ScoreUI/Sources/ScoreUI/EditScoreInfoSheet.swift`
- Modify: `Packages/ScoreUI/Sources/ScoreUI/Resources/Localizable.xcstrings` (add the edit-info keys)
- Delete: `Packages/Features/Library/Sources/Library/Views/EditScoreInfoSheet.swift`
- Delete: `Packages/Features/Library/Sources/Library/Views/EditableScoreInfo+PreFill.swift`

- [ ] **Step 1: Create `EditScoreInfoSheet.swift` in ScoreUI**

Move the sheet from `Library/Views/EditScoreInfoSheet.swift`, applying these changes:
- Make the struct `public` and add a `public init`.
- Replace `let viewModel: LibraryViewModel` with `let model: any ScoreInfoEditing`.
- Replace `viewModel.loadFileMetadata` / `viewModel.saveMetadata` with `model.loadFileMetadata` / `model.saveMetadata`.
- Re-key every `library.score.*` string to `scoreUI.*` (table in Step 3).
- Replace the DEBUG preview's `LibraryViewModel`-based doubles with a single inline `ScoreInfoEditing` fake.

```swift
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
            } label: { L10n.Common.cancel }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button {
                let snapshot = fields
                Task {
                    await model.saveMetadata(item, fields: snapshot)
                    dismiss()
                }
            } label: {
                Label { L10n.Common.save } icon: { Image(systemName: "checkmark") }
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderedProminent)
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
        switch kind {
        case let .museScore(major): "MuseScore \(major)"
        case .musicXML: "MusicXML"
        case .midi: "MIDI"
        case .pdf: "PDF"
        case .unknown, nil:
            String(localized: "scoreUI.source.unknown", bundle: .module)
        }
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
    func loadFileMetadata(for _: ScoreItem) async -> ScoreFileMetadata? {
        ScoreFileMetadata(
            source: .museScore(majorVersion: 4),
            composer: "From File", arranger: nil, lyricist: nil, copyright: "© 2026",
        )
    }

    func saveMetadata(_: ScoreItem, fields _: EditableScoreInfo) async {}
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
#endif
```

- [ ] **Step 2: Delete the Library originals**

```bash
git rm Packages/Features/Library/Sources/Library/Views/EditScoreInfoSheet.swift
git rm Packages/Features/Library/Sources/Library/Views/EditableScoreInfo+PreFill.swift
```

- [ ] **Step 3: Add the edit-info keys to ScoreUI's catalog; remove from Library's**

Copy these entries from Library's `.xcstrings` into `Packages/ScoreUI/Sources/ScoreUI/Resources/Localizable.xcstrings`, renaming keys (preserve all localizations verbatim), then **delete the old keys from Library's catalog**:

| Old key (Library) | New key (ScoreUI) |
| --- | --- |
| `library.score.editInfo.title` | `scoreUI.editInfo.title` |
| `library.score.editInfo.discardAlert.title` | `scoreUI.editInfo.discardAlert.title` |
| `library.score.editInfo.discardAlert.keepEditing` | `scoreUI.editInfo.discardAlert.keepEditing` |
| `library.score.editInfo.discardAlert.discard` | `scoreUI.editInfo.discardAlert.discard` |
| `library.score.field.unsetPlaceholder` | `scoreUI.field.unsetPlaceholder` |
| `library.score.field.title` | `scoreUI.field.title` |
| `library.score.field.subtitle` | `scoreUI.field.subtitle` |
| `library.score.field.composer` | `scoreUI.field.composer` |
| `library.score.field.arranger` | `scoreUI.field.arranger` |
| `library.score.field.lyricist` | `scoreUI.field.lyricist` |
| `library.score.field.copyright` | `scoreUI.field.copyright` |
| `library.score.field.source` | `scoreUI.field.source` |
| `library.score.field.dateAdded` | `scoreUI.field.dateAdded` |
| `library.score.info.section` | `scoreUI.info.section` |
| `library.score.source.unknown` | `scoreUI.source.unknown` |

> Do **not** move `library.score.editInfo.action` (the "Edit Info" menu row in `scoreRowMenu`) — that builder stays in Library, so the key stays too.

- [ ] **Step 4: Build ScoreUI (and render the preview)**

Run (from `Packages/ScoreUI/`): `xcodebuild build -scheme ScoreUI -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation`
Expected: builds clean. Then render `EditScoreInfoSheet`'s `#Preview` via `mcp__xcode__RenderPreview` and `Read` the PNG to confirm the form renders with the credit + info sections (verify Xcode is open on the project first via `mcp__xcode__XcodeListWindows`).

- [ ] **Step 5: Commit**

```bash
git add Packages/ScoreUI Packages/Features/Library
git commit -m "feat(scoreui): move EditScoreInfoSheet into ScoreUI, decouple via ScoreInfoEditing"
```

---

## Task 4: Migrate Library to consume ScoreUI

**Files:**
- Modify: `Packages/Features/Library/Package.swift:15-30`
- Modify: `Packages/Features/Library/Sources/Library/LibraryViewModel.swift`
- Modify: `Packages/Features/Library/Sources/Library/Screens/EditScoreInfoSheetModifier.swift:13`
- Modify: `Packages/Features/Library/Sources/Library/Views/ScoreRowMenu.swift:1-3` (imports)

- [ ] **Step 1: Add the ScoreUI dependency to Library**

In `Packages/Features/Library/Package.swift`, add to `dependencies`:

```swift
        .package(path: "../../ScoreUI"),
```

and to the `Library` target's `dependencies` array:

```swift
                "ScoreUI",
```

- [ ] **Step 2: Update `LibraryViewModel` — remove moved types, conform to `ScoreInfoEditing`, adopt `ScoreShareTarget`**

In `Packages/Features/Library/Sources/Library/LibraryViewModel.swift`:

1. Add `import ScoreUI` at the top.
2. Delete the `EditableScoreInfo` struct (lines 7-14) — it now lives in ScoreUI.
3. Delete the nested `struct ShareTarget` (lines 33-40).
4. Change the stored property `var shareTarget: ShareTarget?` to `var shareTarget: ScoreShareTarget?`.
5. In `requestShare` and `requestBulkShare`, change `ShareTarget(urls:)` to `ScoreShareTarget(urls:)`.
6. Add an empty conformance at the bottom of the file (the existing `loadFileMetadata`/`saveMetadata` methods already match the protocol signatures, so no body changes — conformance stays internal to Library, which is sufficient because the `LibraryViewModel → any ScoreInfoEditing` upcast happens inside the Library module):

```swift
extension LibraryViewModel: ScoreInfoEditing {}
```

- [ ] **Step 3: Update the sheet modifier call site**

In `Packages/Features/Library/Sources/Library/Screens/EditScoreInfoSheetModifier.swift`, line 13, change:

```swift
            EditScoreInfoSheet(viewModel: viewModel, item: item)
```
to:
```swift
            EditScoreInfoSheet(model: viewModel, item: item)
```

Add `import ScoreUI` to that file if not already importing it. Leave the modifier's own `viewModel: LibraryViewModel` parameter name unchanged.

- [ ] **Step 4: Fix imports in `ScoreRowMenu.swift`**

Add `import ScoreUI` to `Packages/Features/Library/Sources/Library/Views/ScoreRowMenu.swift` so the `ShareSubmenu(...)` reference at line 57 resolves.

- [ ] **Step 5: Build & test Library**

Run (from `Packages/Features/Library/`): `xcodebuild test -scheme Library -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation`
Expected: builds clean; all existing Library tests pass (behavior-preserving migration). If the compiler reports any other `EditableScoreInfo`/`ShareTarget`/`ShareSubmenu` reference in Library, add `import ScoreUI` to that file or update the type name; re-run until green.

- [ ] **Step 6: Commit**

```bash
git add Packages/Features/Library
git commit -m "refactor(library): consume ScoreUI for share menu and edit-info sheet"
```

---

## Task 5: Reader view model — inject services, add share + `ScoreInfoEditing`

**Files:**
- Modify: `Packages/Features/Reader/Package.swift:15-35`
- Modify: `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift`
- Create: `Packages/Features/Reader/Sources/Reader/NoopScoreServices.swift`
- Create: `Packages/Features/Reader/Tests/ReaderTests/Fakes/FakeScoreShareService.swift`
- Create: `Packages/Features/Reader/Tests/ReaderTests/Fakes/FakeScoreMetadataReading.swift`
- Create: `Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelShareTests.swift`
- Create: `Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelInfoEditingTests.swift`

- [ ] **Step 1: Add ScoreUI dependency to Reader**

In `Packages/Features/Reader/Package.swift`, add to `dependencies`:

```swift
        .package(path: "../../ScoreUI"),
```

and to the `Reader` target's `dependencies` array:

```swift
                "ScoreUI",
```

- [ ] **Step 2: Add no-op default services (keeps previews/tests arg-free)**

`Packages/Features/Reader/Sources/Reader/NoopScoreServices.swift`:

```swift
import Domain
import Foundation

/// Inert default for `ReaderViewModel.shareService` so previews and tests that don't exercise sharing need no extra
/// argument. Production always injects the real `LiveScoreShareService` from the App composition root.
struct NoopScoreShareService: ScoreShareService {
    func availableFormats(for _: ScoreItem) async -> [ScoreShareFormatOption] { [] }
    func prepareShare(item _: ScoreItem, format _: ScoreShareFormat) async throws -> URL {
        throw DomainError.unsupportedFormat("noop")
    }
}

/// Inert default for `ReaderViewModel.metadataReader`. Production injects the real reader; previews/tests get empty
/// pre-fill.
struct NoopScoreMetadataReading: ScoreMetadataReading {
    func readMetadata(for _: ScoreItem) async throws -> ScoreFileMetadata {
        throw DomainError.unsupportedFormat("noop")
    }
}
```

> Confirm `DomainError.unsupportedFormat(_:)` exists (it is used by `FakeScoreFileGateway`). If the case name differs, use whichever `DomainError` case those fakes throw.

- [ ] **Step 3: Write the failing share test**

`Packages/Features/Reader/Tests/ReaderTests/Fakes/FakeScoreShareService.swift`:

```swift
import Domain
import Foundation

final class FakeScoreShareService: ScoreShareService, @unchecked Sendable {
    var preparedURL = URL(filePath: "/tmp/shared.mscz")
    var formats: [ScoreShareFormatOption] = [ScoreShareFormatOption(format: .museScoreV4, isOriginal: true)]
    private(set) var prepareCallCount = 0

    func availableFormats(for _: ScoreItem) async -> [ScoreShareFormatOption] { formats }

    func prepareShare(item _: ScoreItem, format _: ScoreShareFormat) async throws -> URL {
        prepareCallCount += 1
        return preparedURL
    }
}
```

`Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelShareTests.swift`:

```swift
import Domain
import Foundation
@testable import Reader
import Testing

@MainActor
struct ReaderViewModelShareTests {
    private static func makeItem() -> ScoreItem {
        ScoreItem(
            title: "Test", composer: nil, instrumentationSummary: nil,
            localFileName: "test.mscx", contentHash: "hash",
            sizeBytes: 0, lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastOpenedAt: nil, tagIDs: [], isFavorite: false,
        )
    }

    @Test func `requestShare prepares URL and sets shareTarget`() async {
        let item = Self.makeItem()
        let share = FakeScoreShareService()
        share.preparedURL = URL(filePath: "/tmp/out.pdf")
        let vm = ReaderViewModel(
            scoreItem: item,
            repository: FakeScoreLibraryRepository(),
            gateway: FakeScoreFileGateway(),
            scoresDirectory: URL(filePath: "/tmp"),
            shareService: share,
        )

        await vm.requestShare(format: .pdf)

        #expect(share.prepareCallCount == 1)
        #expect(vm.shareTarget?.urls == [URL(filePath: "/tmp/out.pdf")])
        #expect(vm.isPreparingShare == false)
    }
}
```

- [ ] **Step 4: Run the share test to verify it fails**

Run (from `Packages/Features/Reader/`): `xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation`
Expected: FAIL — `ReaderViewModel` has no `shareService:` init parameter, no `requestShare`, no `shareTarget`/`isPreparingShare`.

- [ ] **Step 5: Implement the view-model changes**

In `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift`:

1. Add `import ScoreUI` at the top.
2. Add observable share/info state near the other presentation flags (after line 49 `isVisualInspectorPresented`):

```swift
    var isScoreInfoPresented = false
    var shareTarget: ScoreShareTarget?
    var isPreparingShare = false
```

3. Add stored services alongside the other `@ObservationIgnored` deps (after `gateway`, lines 53-54):

```swift
    @ObservationIgnored
    private let shareService: any ScoreShareService
    @ObservationIgnored
    let metadataReader: any ScoreMetadataReading
```

4. Add the two parameters to `init` (after `gateway:`), with no-op defaults, and assign them:

```swift
        gateway: any ScoreFileGateway,
        shareService: any ScoreShareService = NoopScoreShareService(),
        metadataReader: any ScoreMetadataReading = NoopScoreMetadataReading(),
        scoresDirectory: URL,
```
```swift
        self.shareService = shareService
        self.metadataReader = metadataReader
```

5. Add the share request method (mirrors `LibraryViewModel.requestShare`). Place it in the main body of the class:

```swift
    func requestShare(format: ScoreShareFormat) async {
        isPreparingShare = true
        defer { isPreparingShare = false }
        do {
            let url = try await shareService.prepareShare(item: scoreItem, format: format)
            shareTarget = ScoreShareTarget(urls: [url])
        } catch {
            // Reader has no error banner yet; sharing failures are non-fatal and simply present nothing.
        }
    }

    /// Lazy format options for the share menu — same source as Library.
    func availableShareFormats() async -> [ScoreShareFormatOption] {
        await shareService.availableFormats(for: scoreItem)
    }
```

6. Add the `ScoreInfoEditing` conformance at the bottom of the file:

```swift
extension ReaderViewModel: ScoreInfoEditing {
    func loadFileMetadata(for item: ScoreItem) async -> ScoreFileMetadata? {
        try? await metadataReader.readMetadata(for: item)
    }

    func saveMetadata(_ item: ScoreItem, fields: EditableScoreInfo) async {
        let trimmedTitle = fields.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }
        var updated = item
        updated.title = trimmedTitle
        updated.subtitle = fields.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.composer = fields.composer.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.arranger = fields.arranger.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.lyricist = fields.lyricist.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.copyright = fields.copyright.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await repository.saveScoreItem(updated)
            scoreItem = updated
        } catch {
            // Non-fatal: keep the in-memory item; no Reader error banner yet.
        }
    }
}
```

> Note: `scoreItem` is `private(set) var` — assigning inside the class is allowed and keeps the Reader's displayed metadata in sync after an edit. `repository` is already a stored property on the view model.

- [ ] **Step 6: Run the share test to verify it passes**

Run (from `Packages/Features/Reader/`): `xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation`
Expected: `ReaderViewModelShareTests` passes; all pre-existing Reader tests still pass (the new init params default to no-ops, so existing `ReaderViewModel(...)` call sites compile unchanged).

- [ ] **Step 7: Write & run the info-editing test**

`Packages/Features/Reader/Tests/ReaderTests/Fakes/FakeScoreMetadataReading.swift`:

```swift
import Domain
import Foundation

final class FakeScoreMetadataReading: ScoreMetadataReading, @unchecked Sendable {
    var metadata = ScoreFileMetadata(
        source: .museScore(majorVersion: 4),
        composer: "File Composer", arranger: nil, lyricist: nil, copyright: nil,
    )

    func readMetadata(for _: ScoreItem) async throws -> ScoreFileMetadata { metadata }
}
```

`Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelInfoEditingTests.swift`:

```swift
import Domain
import Foundation
@testable import Reader
import Testing

@MainActor
struct ReaderViewModelInfoEditingTests {
    private static func makeItem() -> ScoreItem {
        ScoreItem(
            title: "Old", composer: nil, instrumentationSummary: nil,
            localFileName: "test.mscx", contentHash: "hash",
            sizeBytes: 0, lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastOpenedAt: nil, tagIDs: [], isFavorite: false,
        )
    }

    @Test func `loadFileMetadata returns reader's metadata`() async {
        let reader = FakeScoreMetadataReading()
        let vm = ReaderViewModel(
            scoreItem: Self.makeItem(),
            repository: FakeScoreLibraryRepository(),
            gateway: FakeScoreFileGateway(),
            metadataReader: reader,
            scoresDirectory: URL(filePath: "/tmp"),
        )
        let meta = await vm.loadFileMetadata(for: Self.makeItem())
        #expect(meta?.composer == "File Composer")
    }

    @Test func `saveMetadata persists trimmed fields and updates scoreItem`() async {
        let repo = FakeScoreLibraryRepository()
        let item = Self.makeItem()
        let vm = ReaderViewModel(
            scoreItem: item,
            repository: repo,
            gateway: FakeScoreFileGateway(),
            scoresDirectory: URL(filePath: "/tmp"),
        )
        let fields = EditableScoreInfo(
            title: "  New Title  ", subtitle: "", composer: " Bach ",
            arranger: "", lyricist: "", copyright: "",
        )

        await vm.saveMetadata(item, fields: fields)

        #expect(vm.scoreItem.title == "New Title")
        #expect(vm.scoreItem.composer == "Bach")
        #expect(repo.savedScoreItems.last?.title == "New Title")
    }

    @Test func `saveMetadata with blank title is a no-op`() async {
        let repo = FakeScoreLibraryRepository()
        let item = Self.makeItem()
        let vm = ReaderViewModel(
            scoreItem: item,
            repository: repo,
            gateway: FakeScoreFileGateway(),
            scoresDirectory: URL(filePath: "/tmp"),
        )
        await vm.saveMetadata(item, fields: EditableScoreInfo(
            title: "   ", subtitle: "", composer: "", arranger: "", lyricist: "", copyright: "",
        ))
        #expect(vm.scoreItem.title == "Old")
    }
}
```

Add `import ScoreUI` to both new test files (they reference `EditableScoreInfo`).

Run (from `Packages/Features/Reader/`): `xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation`
Expected: all three new info-editing tests pass; `savedScoreItems` is the existing capture array on `FakeScoreLibraryRepository` (confirm the property name; if it differs, assert against the actual capture).

- [ ] **Step 8: Commit**

```bash
git add Packages/Features/Reader
git commit -m "feat(reader): view-model share + score-info editing via ScoreUI"
```

---

## Task 6: Reader toolbar — "this score" pill + presentations

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/ReaderToolbar.swift` (`ReaderTopOverlay`)
- Modify: `Packages/Features/Reader/Sources/Reader/Resources/<the .xcstrings file>`

- [ ] **Step 1: Add the two new Reader toolbar strings**

In Reader's `.xcstrings`, add keys (English values shown; mirror the existing `reader.toolbar.*` entry style):
- `reader.toolbar.showInfo` → "Score Info"
- `reader.toolbar.share` → "Share"

- [ ] **Step 2: Add a "this score" pill to `ReaderTopOverlay`**

In `Packages/Features/Reader/Sources/Reader/Screens/ReaderToolbar.swift`:

1. Add `import ScoreUI` and (if not present) `import UtilityUI` at the top.
2. In `ReaderTopOverlay`, render a new pill to the **left** of the existing inspector pill. Wrap both pills in an `HStack` with a gap, keeping the existing `inspectorButtons(score:)` pill right-most. Add the "this score" pill builder:

```swift
    private func scoreActionButtons(score: Score) -> some View {
        HStack(spacing: 0) {
            overlayButton(
                systemImage: "info.circle",
                label: Text("reader.toolbar.showInfo", bundle: .module),
            ) {
                viewModel.isScoreInfoPresented = true
            }

            Menu {
                ShareSubmenu(
                    loadFormats: { [viewModel] in await viewModel.availableShareFormats() },
                    onShare: { format in
                        Task { await viewModel.requestShare(format: format) }
                    },
                )
            } label: {
                overlayButtonLabel(
                    systemImage: "square.and.arrow.up",
                    label: Text("reader.toolbar.share", bundle: .module),
                )
            }
        }
        .glassEffect(.regular.interactive())
        .shadow(color: .gray.opacity(0.3), radius: 10, y: 5)
    }
```

> The existing pill is built by `inspectorButtons(score:)` and already carries `.glassEffect`/`.shadow`. Match those exact modifiers here so both pills read identically. If `overlayButton` bakes in its own background, factor out a label-only helper (`overlayButtonLabel`) so the `Menu`'s label matches the tappable buttons; otherwise reuse the existing label styling. Inspect the current `overlayButton` implementation in this file and mirror its glyph sizing/padding.

3. Place the two pills together where `inspectorButtons` is currently used, e.g.:

```swift
            HStack(spacing: 12) {
                scoreActionButtons(score: score)
                inspectorButtons(score: score)
            }
```

(keep this group in the same top-trailing alignment the inspector pill already had).

- [ ] **Step 3: Present the info sheet and the share sheet**

Attach to `ReaderTopOverlay`'s body (or the screen that hosts it — match where existing `.popover`s live; the inspector popovers are on the buttons inside this file, so co-locate these here):

```swift
        .sheet(isPresented: $viewModel.isScoreInfoPresented) {
            EditScoreInfoSheet(model: viewModel, item: viewModel.scoreItem)
        }
        .sheet(item: $viewModel.shareTarget) { target in
            ActivityViewControllerRepresentable(items: target.urls)
        }
```

> `$viewModel.shareTarget` / `$viewModel.isScoreInfoPresented` need `@Bindable`. `ReaderTopOverlay` already binds the view model for the inspector popovers (`$viewModel.isPlaybackInspectorPresented`), so the same binding mechanism applies — follow the existing pattern in this file. `ActivityViewControllerRepresentable` comes from `UtilityUI`.

- [ ] **Step 4: Build Reader & render the toolbar preview**

Run (from `Packages/Features/Reader/`): `xcodebuild build -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation`
Expected: builds clean.

Then verify Xcode is open (`mcp__xcode__XcodeListWindows`), render the `ReaderTopOverlay` preview at the bottom of `ReaderToolbar.swift` (the `ReaderViewModel(...)` preview at line ~225) via `mcp__xcode__RenderPreview`, and `Read` the PNG. Confirm: two distinct glass pills, "this score" (info + share) on the left, "settings" (sliders + page) on the right, with a visible gap. If the preview's `ReaderViewModel(...)` lacks the new services it still compiles (no-op defaults) — the share menu will show placeholder formats, which is fine for layout verification.

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Reader
git commit -m "feat(reader): add this-score pill (info + share) to the top overlay"
```

---

## Task 7: App composition — wire services into `ReaderRootScreen`

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen.swift:38-64`
- Modify: `App/AppShellView.swift` (3 `ReaderRootScreen(...)` call sites, ~lines 199, 334, 361)

- [ ] **Step 1: Thread the services through `ReaderRootScreen.init`**

In `ReaderRootScreen.swift`, add the two parameters to the public init (after `gateway:`) and pass them to `ReaderViewModel`:

```swift
        gateway: any ScoreFileGateway,
        shareService: any ScoreShareService,
        metadataReader: any ScoreMetadataReading,
        scoresDirectory: URL,
```
```swift
            wrappedValue: ReaderViewModel(
                scoreItem: scoreItem,
                repository: repository,
                gateway: gateway,
                shareService: shareService,
                metadataReader: metadataReader,
                scoresDirectory: scoresDirectory,
                defaultStaffSize: initialDefault,
                playbackController: playbackController,
                museScoreGeneralProvider: museScoreGeneralProvider,
            ),
```

> These are required (no default) at the screen boundary — the App always has them, and requiring them surfaces missing wiring at compile time.

- [ ] **Step 2: Pass them at the 3 App call sites**

In `App/AppShellView.swift`, the `ReadyShell` struct already holds `shareService` (line 100) and `metadataReader` (line 101). Add `shareService: shareService,` and `metadataReader: metadataReader,` to each of the three `ReaderRootScreen(...)` invocations (after `gateway: gateway,`), at ~lines 199, 334, 361.

- [ ] **Step 3: Regenerate the project & build the whole app**

Run (from repo root): `xcodegen generate`
Then: `xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation build`
Expected: the app builds; the new `ScoreUI` package is resolved and linked.

- [ ] **Step 4: Commit**

```bash
git add Packages/Features/Reader App project.yml
git commit -m "feat(app): inject share + metadata services into ReaderRootScreen"
```

---

## Task 8: Record the `ScoreUI` layer in the architecture doc

**Files:**
- Modify: `docs/engineering/module-architecture.md:5-34`

- [ ] **Step 1: Update the layer diagram and bullets**

Add a `ScoreUI` bullet under the Layers list (after the `Packages/Features/<Name>/` bullet) and reflect the new edge in the ASCII graph. Suggested wording:

> - **`Packages/ScoreUI/`** — shared, score-aware SwiftUI components reused across Features (e.g. the share-format menu and the edit-info sheet). Depends on Domain + Utility only; must not depend on any Feature or App. Exists because such components need Domain types yet must be shared without a `Feature → Feature` edge — which Domain (Foundation-only) and Utility (Domain-free) cannot host.

Update the graph to show `Features ──▶ ScoreUI ──▶ Domain` and `ScoreUI ──▶ Utility`.

- [ ] **Step 2: Update the Forbidden list**

Under **Forbidden**, add:

> - `ScoreUI → Feature / Infrastructure / App` (ScoreUI sits below Features and may only use Domain + Utility).

and clarify the existing `Feature → Feature` line still holds (shared code goes into `ScoreUI`, Domain, or App composition).

- [ ] **Step 3: Commit**

```bash
git add docs/engineering/module-architecture.md
git commit -m "docs(arch): add ScoreUI shared feature-UI layer"
```

---

## Task 9: Localization stale-key audit + final verification

**Files:** (verification only; fixes inline if needed)

- [ ] **Step 1: Confirm no orphaned keys remain in Library's catalog**

Search the Library sources for any lingering reference to the moved keys:

Run: `grep -rn "library.score.field\|library.score.editInfo.title\|library.score.editInfo.discardAlert\|library.score.info.section\|library.score.source.unknown\|library.format\|library.score.field.unsetPlaceholder" Packages/Features/Library/Sources/`
Expected: no matches except `library.score.editInfo.action` (the menu row, intentionally kept). If a moved key still appears in Library's `.xcstrings`, delete that entry.

- [ ] **Step 2: Confirm ScoreUI defines every key it references**

Run: `grep -rno "scoreUI\.[A-Za-z0-9.]*" Packages/ScoreUI/Sources/ScoreUI/`
Cross-check each printed key exists in `Packages/ScoreUI/Sources/ScoreUI/Resources/Localizable.xcstrings`. Add any missing entry (copying its localizations from the Library originals in git history if needed).

- [ ] **Step 3: Whole-app clean build + the two feature test suites**

Run (repo root): `xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation build`
Run (from `Packages/Features/Library/`): `xcodebuild test -scheme Library -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation`
Run (from `Packages/Features/Reader/`): `xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation`
Expected: app builds; Library and Reader suites green.

- [ ] **Step 4: Manual smoke (hand off to user)**

Per project convention, do not drive the simulator programmatically. Summarize for the user to verify by hand: open a score → top-right shows two pills → tap info (sheet shows credits + source/date, edit + save persists) → tap share (menu lists 5 formats, original marked, picking one presents the iOS share sheet). Library share + edit-info unchanged.

- [ ] **Step 5: Final commit (if the audit changed anything)**

```bash
git add -A
git commit -m "chore(l10n): audit ScoreUI/Library string-catalog key migration"
```

---

## Self-Review

**Spec coverage:**
- 2+2 grouped pill → Task 6. ✓
- Share scope = Library's 5 formats via existing `ScoreShareService` → Tasks 2, 5, 6 (no new export code). ✓
- Reuse Library's `EditScoreInfoSheet` (edit-capable) → Tasks 3, 4, 6. ✓
- New `ScoreUI` package + dependencies → Tasks 1, 4, 5; arch doc → Task 8. ✓
- Decouple sheet from `LibraryViewModel` via `ScoreInfoEditing` → Tasks 1, 3, 4, 5. ✓
- Promote `ScoreShareTarget` → Tasks 1, 4, 5. ✓
- Reader needs `shareService` + `metadataReader` → Tasks 5, 7. ✓
- App wiring (3 sites) → Task 7. ✓
- Localization re-key + stale-key audit → Tasks 2, 3, 9. ✓
- Library migration regression bar → Tasks 4, 9. ✓
- project.yml registration → Task 1 (added) + regenerate Task 7. ✓

**Type consistency:** `ScoreInfoEditing` (`loadFileMetadata(for:) async -> ScoreFileMetadata?`, `saveMetadata(_:fields:) async`) matches `LibraryViewModel`'s existing signatures (Task 4 empty conformance) and Reader's new ones (Task 5). `ScoreShareTarget(urls:)` consistent across Tasks 1/4/5. `ShareSubmenu(loadFormats:onShare:)` signature unchanged from the original, used by Library (Task 4) and Reader (Task 6). `EditScoreInfoSheet(model:item:)` consistent across Tasks 3/4/6.

**Open follow-ups (not blocking, called out for the implementer):**
- Verify `DomainError.unsupportedFormat(_:)` case name (Task 5 Step 2) and `FakeScoreLibraryRepository`'s capture-array property name (`savedScoreItems`, Task 5 Step 7) against the real sources; adjust if different.
- `overlayButton` internal structure (Task 6 Step 2) — mirror the existing helper's label styling so the `Menu` label matches tappable buttons.
