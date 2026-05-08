# Reader global settings — mirror in Settings sheet — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Promote Reader's layout direction to a global `@AppStorage` setting (alongside the existing metronome toggle) and mirror both controls in the Library Settings sheet, with the running playback engine staying in sync when metronome flips on iPad split view.

**Architecture:** Lift `LayoutMode` and the two `@AppStorage` key constants into Domain so Settings can reference them without an illegal Feature → Feature dependency. Move the metronome engine push from Inspector's `.task` up to `ReaderView`, where it's driven by `.task` + `.onChange(of:)` against the shared key — that's what fixes the iPad concurrent-screen case where Settings flips the toggle while a Reader detail pane is alive in the same scene.

**Tech Stack:** Swift 6.3, SwiftUI `@AppStorage` (UserDefaults under the hood), Swift Testing (`@Test`, `#expect`), iOS 26 / macOS 15 SwiftPM packages.

**Spec:** `docs/superpowers/specs/2026-05-08-reader-global-settings-mirror-design.md`

---

## File Map

**Created:**
- `Packages/Domain/Sources/Domain/Models/ReaderLayoutMode.swift` — top-level `ReaderLayoutMode` enum + `ReaderGlobalSettingsKey` namespace.
- `Packages/Domain/Tests/DomainTests/Models/ReaderLayoutModeTests.swift` — verifies enum cases, raw values, and the two key constants.

**Deleted:**
- `Packages/Features/Reader/Sources/Reader/ReaderLayoutMode.swift` — was a nested `ReaderViewModel.LayoutMode`; superseded by the Domain enum.

**Modified:**
- `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift` — drop the transient `var layoutMode` property and its initializer/usage. The VM no longer owns layout direction.
- `Packages/Features/Reader/Sources/Reader/ReaderView.swift` — own both `@AppStorage` keys; derive a `ReaderLayoutMode` for the render switch; drive metronome engine sync via `.task` (initial) + `.onChange(of:)`.
- `Packages/Features/Reader/Sources/Reader/InspectorView.swift` — bind metronome button + layout picker to the shared `@AppStorage` keys; drop the `.task { setMetronomeEnabled }` bootstrap.
- `Packages/Features/Settings/Sources/Settings/SettingsSheet.swift` — add a new "Reader" `Section` above Storage with a metronome `Toggle` and a layout-direction `Picker`.
- `Packages/Features/Settings/Sources/Settings/Resources/Localizable.xcstrings` — add three keys: `Reader`, `Metronome`, `Layout direction` (en + ja).

**Untouched (verified in plan):**
- `ReaderViewModel.setMetronomeEnabled(_:)` — kept as the engine-side forwarder; ReaderView calls it from its `.task` / `.onChange` hooks.
- The existing `@AppStorage("readerMetronomeEnabled")` user defaults key is preserved verbatim via `ReaderGlobalSettingsKey.metronomeEnabled` so user state survives the refactor.

---

## Task 1: Lift `ReaderLayoutMode` and key constants into Domain

**Files:**
- Create: `Packages/Domain/Sources/Domain/Models/ReaderLayoutMode.swift`
- Create: `Packages/Domain/Tests/DomainTests/Models/ReaderLayoutModeTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Packages/Domain/Tests/DomainTests/Models/ReaderLayoutModeTests.swift`:

```swift
import Domain
import Testing

@Suite
struct ReaderLayoutModeTests {
    @Test func rawValuesAreStable() {
        #expect(ReaderLayoutMode.vertical.rawValue == "vertical")
        #expect(ReaderLayoutMode.horizontal.rawValue == "horizontal")
    }

    @Test func allCasesContainsBoth() {
        #expect(ReaderLayoutMode.allCases == [.vertical, .horizontal])
    }

    @Test func metronomeKeyMatchesLegacyAppStorage() {
        // The string literal is load-bearing: existing user state lives under
        // this key, so changing it would silently reset every install.
        #expect(ReaderGlobalSettingsKey.metronomeEnabled == "readerMetronomeEnabled")
    }

    @Test func layoutModeKeyIsStable() {
        #expect(ReaderGlobalSettingsKey.layoutMode == "readerLayoutMode")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Packages/Domain && swift test --filter ReaderLayoutModeTests`

Expected: FAIL with "cannot find type 'ReaderLayoutMode' in scope" (and similar for `ReaderGlobalSettingsKey`).

- [ ] **Step 3: Create the Domain types**

Create `Packages/Domain/Sources/Domain/Models/ReaderLayoutMode.swift`:

```swift
import Foundation

/// How the Reader lays out the score in the viewport.
///
/// `.vertical` wraps systems to fit the view width and scrolls vertically;
/// `.horizontal` lays the score out at its natural width as one long row
/// that scrolls horizontally.
public enum ReaderLayoutMode: String, CaseIterable, Sendable, Hashable {
    case vertical
    case horizontal
}

/// `@AppStorage` keys for Reader settings that persist across sessions
/// and apply to every score. Co-located with `ReaderLayoutMode` so the
/// raw strings are not duplicated as literals across packages.
public enum ReaderGlobalSettingsKey {
    /// Bool. Preserved verbatim from the pre-refactor key so existing
    /// user state survives the refactor — do not rename.
    public static let metronomeEnabled = "readerMetronomeEnabled"

    /// `ReaderLayoutMode.rawValue` (String).
    public static let layoutMode = "readerLayoutMode"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd Packages/Domain && swift test --filter ReaderLayoutModeTests`

Expected: 4 tests pass.

- [ ] **Step 5: Run the whole Domain suite to confirm no regression**

Run: `cd Packages/Domain && swift test`

Expected: existing Domain tests + the 4 new ones all pass.

- [ ] **Step 6: Commit**

```bash
git add Packages/Domain/Sources/Domain/Models/ReaderLayoutMode.swift \
        Packages/Domain/Tests/DomainTests/Models/ReaderLayoutModeTests.swift
git commit -m "feat(domain): add ReaderLayoutMode and ReaderGlobalSettingsKey"
```

---

## Task 2: Drop the nested LayoutMode and the VM's transient layout property

**Files:**
- Delete: `Packages/Features/Reader/Sources/Reader/ReaderLayoutMode.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift:47`

This task isolates the VM-side cleanup. Views still reference `viewModel.layoutMode` after this step — they're updated in Task 3, which is why we batch the VM and View edits across two tasks but keep them in one commit-worthy unit at the end.

- [ ] **Step 1: Delete the Reader-local enum file**

Run: `rm Packages/Features/Reader/Sources/Reader/ReaderLayoutMode.swift`

(The file's only contents were the nested `ReaderViewModel.LayoutMode` enum, now superseded by `Domain.ReaderLayoutMode`.)

- [ ] **Step 2: Remove the transient `layoutMode` property from the VM**

Edit `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift`. Delete line 47:

```swift
    public var layoutMode: LayoutMode = .vertical
```

Do not delete `setMetronomeEnabled(_:)` (lines 463–465) — it remains the engine-side forwarder that `ReaderView` will call from its hooks.

- [ ] **Step 3: Verify the package still builds (will fail in views, expected)**

Run: `cd Packages/Features/Reader && swift build` (do not commit yet — view files reference `viewModel.layoutMode` and `ReaderViewModel.LayoutMode`).

Expected: build FAILs in `ReaderView.swift` ("value of type 'ReaderViewModel' has no member 'layoutMode'") and in `InspectorView.swift` ("type 'ReaderViewModel' has no member type named 'LayoutMode'"). These are fixed in Task 3.

- [ ] **Step 4: Do not commit yet**

Move on to Task 3. The combined VM + view rewrite lands as one commit at the end of Task 3 because the intermediate state does not build.

---

## Task 3: Rewire ReaderView and InspectorView to the AppStorage-backed mode

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/ReaderView.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/InspectorView.swift`
- Add: `Reader/Package.swift` already depends on `Domain`, no manifest change needed.

- [ ] **Step 1: Rewrite `ReaderView` to own the AppStorage values and forward metronome changes**

Edit `Packages/Features/Reader/Sources/Reader/ReaderView.swift`. Replace the struct body with:

```swift
import Domain
import SheetMusicCore
import SwiftUI

@MainActor
public struct ReaderView: View {
    @State private var viewModel: ReaderViewModel
    @Environment(\.dismiss) private var dismiss
    private let onBack: (() -> Void)?

    @AppStorage(ReaderGlobalSettingsKey.layoutMode)
    private var layoutModeRaw: String = ReaderLayoutMode.vertical.rawValue

    @AppStorage(ReaderGlobalSettingsKey.metronomeEnabled)
    private var isMetronomeEnabled: Bool = false

    private var layoutMode: ReaderLayoutMode {
        ReaderLayoutMode(rawValue: layoutModeRaw) ?? .vertical
    }

    public init(
        scoreItem: ScoreItem,
        repository: any ScoreLibraryRepository,
        gateway: any ScoreFileGateway,
        scoresDirectory: URL,
        playbackController: (any PlaybackController)? = nil,
        reachability: (any NetworkReachability)? = nil,
        onBack: (() -> Void)? = nil
    ) {
        let initialDefault: CGFloat = 14 // TBD: device-class override (follow-up)
        _viewModel = State(
            wrappedValue: ReaderViewModel(
                scoreItem: scoreItem,
                repository: repository,
                gateway: gateway,
                scoresDirectory: scoresDirectory,
                defaultStaffSize: initialDefault,
                playbackController: playbackController,
                reachability: reachability
            )
        )
        self.onBack = onBack
    }

    public var body: some View {
        ZStack {
            #if os(iOS)
                content
                    .safeAreaPadding(.top, ReaderTopOverlay.height)
            #else
                content
            #endif
            VStack(spacing: 0) {
                #if os(iOS)
                    ReaderTopOverlay(
                        viewModel: viewModel,
                        onBack: onBack ?? { dismiss() }
                    )
                #endif
                Spacer()
                ReaderBottomOverlay(viewModel: viewModel)
            }
        }
        .navigationTitle("")
        .readerToolbar(viewModel: viewModel)
        .inspector(isPresented: $viewModel.isInspectorPresented) {
            if case let .loaded(score) = viewModel.loadState {
                InspectorView(viewModel: viewModel, score: score)
                    .presentationDetents([.medium, .large])
            } else {
                Color.clear
            }
        }
        .alert(
            soundfontAlertTitle(for: viewModel.soundfontAlertKind),
            isPresented: Binding(
                get: { viewModel.soundfontAlertKind != nil },
                set: { newValue in
                    if !newValue { viewModel.cancelLoadingSoundfonts() }
                }
            )
        ) {
            Button(role: .cancel) {
                viewModel.cancelLoadingSoundfonts()
            } label: {
                Text("Cancel", bundle: .module)
            }
        }
        .task {
            viewModel.startObservingCursor()
            await viewModel.load()
            await viewModel.prepareForPlayback()
            // Initial sync: the engine starts up unaware of persisted state,
            // so seed it from the @AppStorage value at view start.
            await viewModel.setMetronomeEnabled(isMetronomeEnabled)
        }
        .onChange(of: isMetronomeEnabled) { _, newValue in
            // The iPad fix: if the user toggles metronome from the Settings
            // sheet while a Reader detail pane is alive in the same scene,
            // the running engine has to be reconfigured here — the
            // Inspector's button no longer drives that side effect.
            Task { await viewModel.setMetronomeEnabled(newValue) }
        }
    }

    private func soundfontAlertTitle(
        for kind: ReaderViewModel.SoundfontAlertKind?
    ) -> String {
        switch kind {
        case .offline:
            String(localized: "You're offline", bundle: .module)
        case .loading, nil:
            String(localized: "Loading playback sounds…", bundle: .module)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.loadState {
        case .loading:
            ProgressView().controlSize(.large)
        case let .loaded(score):
            let visible = score.filtered(hidingStaves: viewModel.preferences.hiddenStaves)
            switch layoutMode {
            case .vertical:
                VerticalScoreContainer(
                    score: visible,
                    staffSize: viewModel.preferences.staffSize,
                    honorLayoutBreaks: viewModel.preferences.honorLayoutBreaks,
                    playbackCursor: viewModel.playbackCursor,
                    viewModel: viewModel
                )
            case .horizontal:
                HorizontalScoreContainer(
                    score: visible,
                    staffSize: viewModel.preferences.staffSize,
                    honorLayoutBreaks: viewModel.preferences.honorLayoutBreaks,
                    playbackCursor: viewModel.playbackCursor,
                    viewModel: viewModel
                )
            }
        case let .failed(message):
            ContentUnavailableView {
                Label {
                    Text("Could not open this score", bundle: .module)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
            } description: {
                Text(message)
            } actions: {
                Button { Task { await viewModel.load() } } label: {
                    Text("Retry", bundle: .module)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}

#if DEBUG
    /// Documents the shape of a real Score fixture. Not used by the previews
    /// below — building a `ReaderView` preview requires wiring a fake gateway
    /// that returns a real `Score`, which is too brittle for a preview. See
    /// `InspectorView` for a productive Score-shaped preview.
    @MainActor
    private func previewScore() -> Score {
        Score(
            division: 480,
            parts: [],
            metaTags: ["workTitle": "Sample"]
        )
    }

    #Preview("Loading") {
        ProgressView().controlSize(.large)
    }

    #Preview("Loaded · vertical · iPhone") {
        Text("Run via xcode preview to see the assembled view")
    }
#endif
```

The changes vs. the existing file:
1. Two `@AppStorage` properties + a `layoutMode` computed.
2. `switch viewModel.layoutMode` becomes `switch layoutMode`.
3. `.task` adds an `await viewModel.setMetronomeEnabled(isMetronomeEnabled)` line at the end.
4. New `.onChange(of: isMetronomeEnabled)` modifier.

- [ ] **Step 2: Rewire `InspectorView` bindings to AppStorage**

Edit `Packages/Features/Reader/Sources/Reader/InspectorView.swift`. Three edits:

**Edit A — extend the `@AppStorage` block at the top of the struct (around line 10):**

```swift
    @AppStorage(ReaderGlobalSettingsKey.metronomeEnabled) private var isMetronomeEnabled: Bool = false
    @AppStorage(ReaderGlobalSettingsKey.layoutMode)
    private var layoutModeRaw: String = ReaderLayoutMode.vertical.rawValue
```

(The metronome AppStorage line already exists with a hard-coded string; replace its key with the constant.)

**Edit B — drop the metronome bootstrap `.task`. In `body`, remove this block (currently lines 59–61):**

```swift
        .task {
            await viewModel.setMetronomeEnabled(isMetronomeEnabled)
        }
```

(The other `.task(id: viewModel.effectiveTempoMultiplier) { … }` immediately above it stays — it syncs the tempo slider, unrelated.)

**Edit C — replace the layout picker (currently lines 113–128):**

```swift
    @ViewBuilder
    private var layoutRow: some View {
        HStack {
            Text("Layout direction", bundle: .module)
            Spacer()
            Picker(selection: $layoutModeRaw) {
                Image(systemName: "arrow.up.and.down")
                    .tag(ReaderLayoutMode.vertical.rawValue)
                Image(systemName: "arrow.left.and.right")
                    .tag(ReaderLayoutMode.horizontal.rawValue)
            } label: {
                Text("Layout direction", bundle: .module)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 92)
            .fixedSize()
        }
    }
```

**Edit D — simplify the metronome button in `tempoControls` (currently lines 177–187):**

```swift
            Button {
                isMetronomeEnabled.toggle()
            } label: {
                Image(systemName: isMetronomeEnabled ? "metronome.fill" : "metronome")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 24, height: 24)
                    .padding(.horizontal, 4)
            }
```

The previous `Task { await viewModel.setMetronomeEnabled(isMetronomeEnabled) }` inside the button is removed — `ReaderView`'s `.onChange` is now the single forwarder.

- [ ] **Step 3: Build the Reader package**

Run: `cd Packages/Features/Reader && swift build`

Expected: SUCCESS (the references to `viewModel.layoutMode` and `ReaderViewModel.LayoutMode` are all gone).

- [ ] **Step 4: Run the existing Reader test suite**

Run: `cd Packages/Features/Reader && swift test`

Expected: all tests pass. In particular `ReaderViewModelTempoTests.setMetronomeEnabledForwardsWithoutPersisting` continues to pass — `vm.setMetronomeEnabled` is unchanged.

- [ ] **Step 5: Commit Tasks 2 + 3 together**

```bash
git add Packages/Features/Reader/Sources/Reader/ReaderLayoutMode.swift \
        Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift \
        Packages/Features/Reader/Sources/Reader/ReaderView.swift \
        Packages/Features/Reader/Sources/Reader/InspectorView.swift
git commit -m "refactor(reader): switch layoutMode to @AppStorage, lift metronome forwarding to ReaderView"
```

(`git add` of a deleted file stages the deletion.)

---

## Task 4: Add the Reader section to the Settings sheet

**Files:**
- Modify: `Packages/Features/Settings/Sources/Settings/SettingsSheet.swift`
- Modify: `Packages/Features/Settings/Sources/Settings/Resources/Localizable.xcstrings`

- [ ] **Step 1: Add the localization keys**

Edit `Packages/Features/Settings/Sources/Settings/Resources/Localizable.xcstrings`. Insert three entries (alphabetical insertion within the `"strings"` object — locate them by key, the file is sorted by key string):

```json
    "Layout direction" : {
      "localizations" : {
        "en" : {
          "stringUnit" : { "state" : "translated", "value" : "Layout direction" }
        },
        "ja" : {
          "stringUnit" : { "state" : "translated", "value" : "レイアウト方向" }
        }
      }
    },
    "Metronome" : {
      "localizations" : {
        "en" : {
          "stringUnit" : { "state" : "translated", "value" : "Metronome" }
        },
        "ja" : {
          "stringUnit" : { "state" : "translated", "value" : "メトロノーム" }
        }
      }
    },
    "Reader" : {
      "localizations" : {
        "en" : {
          "stringUnit" : { "state" : "translated", "value" : "Reader" }
        },
        "ja" : {
          "stringUnit" : { "state" : "translated", "value" : "リーダー" }
        }
      }
    },
```

(Match the surrounding indentation — two-space, with a trailing comma after each entry.)

- [ ] **Step 2: Wire the new section in `SettingsSheet`**

Edit `Packages/Features/Settings/Sources/Settings/SettingsSheet.swift`. Two changes:

**Edit A — add `@AppStorage` properties at the top of the struct (after the `@State` properties, around line 13):**

```swift
    @AppStorage(ReaderGlobalSettingsKey.metronomeEnabled)
    private var isMetronomeEnabled: Bool = false

    @AppStorage(ReaderGlobalSettingsKey.layoutMode)
    private var layoutModeRaw: String = ReaderLayoutMode.vertical.rawValue
```

**Edit B — insert a `readerSection` call inside the `Form` (line 27 area), above the optional `storageSection`:**

```swift
        NavigationStack {
            Form {
                readerSection
                if let soundfontResolver {
                    storageSection(resolver: soundfontResolver)
                }
                aboutSection
            }
```

**Edit C — add the `readerSection` view builder (place it next to `storageSection`, around line 60):**

```swift
    private var readerSection: some View {
        Section {
            Toggle(isOn: $isMetronomeEnabled) {
                Label {
                    Text("Metronome", bundle: .module)
                } icon: {
                    Image(systemName: isMetronomeEnabled ? "metronome.fill" : "metronome")
                }
            }

            Picker(selection: $layoutModeRaw) {
                Label {
                    Text("Vertical", bundle: .module)
                } icon: {
                    Image(systemName: "arrow.up.and.down")
                }
                .tag(ReaderLayoutMode.vertical.rawValue)

                Label {
                    Text("Horizontal", bundle: .module)
                } icon: {
                    Image(systemName: "arrow.left.and.right")
                }
                .tag(ReaderLayoutMode.horizontal.rawValue)
            } label: {
                Label {
                    Text("Layout direction", bundle: .module)
                } icon: {
                    Image(systemName: "rectangle.split.1x2")
                }
            }
        } header: {
            Text("Reader", bundle: .module)
        }
    }
```

The "Vertical" / "Horizontal" labels reuse strings already present in the Settings xcstrings file from existing UI; if the lint step in Step 4 reports them as missing, add them with the same en/ja pattern in `Localizable.xcstrings`.

- [ ] **Step 3: Build the Settings package**

Run: `cd Packages/Features/Settings && swift build`

Expected: SUCCESS. `Domain` is already a declared dependency, so `ReaderLayoutMode` and `ReaderGlobalSettingsKey` resolve.

- [ ] **Step 4: Run the Settings test suite**

Run: `cd Packages/Features/Settings && swift test`

Expected: existing `SettingsSheetTests.sheetConstructsWithStubLicenseContent` and `…WithStubResolver` pass — the body still constructs cleanly with the new section.

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Settings/Sources/Settings/SettingsSheet.swift \
        Packages/Features/Settings/Sources/Settings/Resources/Localizable.xcstrings
git commit -m "feat(settings): mirror Reader metronome and layout direction in Settings sheet"
```

---

## Task 5: End-to-end verification on simulator

**Files:** none (manual verification step).

The unit tests in Tasks 1, 3, and 4 cover the seams that can be exercised without a running app. The iPad concurrent-screen behavior described in the spec is a system-level integration that has to be observed in a real run.

- [ ] **Step 1: Full project build**

Run from the worktree root:

```bash
xcodebuild -project Folino.xcodeproj -scheme Folino \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -skipPackagePluginValidation build
```

Expected: BUILD SUCCEEDED. (If `Folino.xcodeproj` isn't present, regenerate first: `xcodegen generate`.)

- [ ] **Step 2: Manual verification — iPhone, layout persistence**

Launch the app on iPhone 16 simulator. Open a score → Inspector → switch layout to horizontal → close Reader → open Settings from Library → confirm picker shows horizontal. Force-quit + relaunch → Settings still horizontal, Reader opens horizontal.

- [ ] **Step 3: Manual verification — iPhone, metronome from Settings**

From Library: Settings → toggle metronome OFF → open a score → press play → no metronome click. Toggle ON via Settings → play → click audible.

- [ ] **Step 4: Manual verification — iPad split view, layout sync**

Switch destination to iPad (e.g. `name=iPad Pro 13-inch (M4)`) and rebuild. Open Reader on the right pane, leave Library + Settings on the left. Change layout direction in Settings → Reader pane re-flows immediately.

- [ ] **Step 5: Manual verification — iPad split view, metronome while playing**

Same iPad destination. Open Reader, press play. Open Settings from Library (left pane). Toggle metronome ON → click starts on the running playback without dismissing the sheet. Toggle OFF → click stops.

- [ ] **Step 6: No commit**

This is verification-only. If any step fails, return to the relevant task and fix; once all five manual steps pass, the feature is done.

---

## Self-Review (completed before handoff)

**Spec coverage:**
- "Domain — lift the enum and key constants" → Task 1.
- "Reader — switch layoutMode to @AppStorage, fold metronome push into the screen" → Tasks 2 + 3.
- "Settings — new 'Reader' section" → Task 4.
- Localization (Reader / Metronome / Layout direction) → Task 4 Step 1.
- iPad concurrent-screen behavior → covered by Task 3's `.onChange` wiring and verified in Task 5 Steps 4–5.
- Verification block (lines 99–107 of the spec) → mapped 1:1 to Task 5 Steps 2–5.
- Non-goals are honored: no Domain protocol introduced, metronome key string preserved.

**Type / name consistency:**
- `ReaderLayoutMode` (Domain) used in ReaderView, InspectorView, SettingsSheet. No `ReaderViewModel.LayoutMode` references remain after Task 2 Step 2.
- `ReaderGlobalSettingsKey.metronomeEnabled` / `.layoutMode` used for every `@AppStorage` site introduced (Reader and Settings).
- The legacy `"readerMetronomeEnabled"` literal exists in exactly one place after Task 1: `ReaderGlobalSettingsKey.metronomeEnabled`'s initializer. The Domain test in Task 1 Step 1 pins that string so an accidental rename trips a build-time test.
