# Incoming URL — pop early & loading HUD — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a URL arrives via `.onOpenURL`, immediately reset navigation to library root and show a fullscreen loading HUD until the import resolves (success / duplicate / error).

**Architecture:** Add an `isImporting` flag to `LibraryViewModel` driven by `defer` inside `startImport(from:)` and `commit(plan:decision:)`. Move the navigation-reset (compactPath / detailScoreItem clearing) from the post-import handler in `AppShellView` to a new pre-import handler that fires the moment `bootstrap.pendingIncomingURL` is consumed. Show a HUD overlay on `AppShellView` while `libraryVM.isImporting` is true.

**Tech Stack:** SwiftUI, `@Observable`, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-05-09-incoming-url-loading-hud-design.md`

---

## File Structure

| File | Change | Responsibility |
|---|---|---|
| `Packages/Features/Library/Sources/Library/LibraryViewModel.swift` | Modify | Add `isImporting` property; wrap `startImport` and `commit` with `defer` |
| `Packages/Features/Library/Tests/LibraryTests/LibraryViewModelTests.swift` | Modify | Add tests verifying `isImporting` is `false` after each exit path |
| `App/AppShellView.swift` | Modify | Add `resetNavigationForIncomingURL()`, call it before kicking off import; add `ImportLoadingHUD` private view + `.overlay` |
| `App/Resources/Localizable.xcstrings` | Modify | Add key `app.import.loading.label` (en + ja) |

---

## Task 1: `LibraryViewModel.isImporting` flag (TDD)

**Files:**
- Modify: `Packages/Features/Library/Sources/Library/LibraryViewModel.swift`
- Test: `Packages/Features/Library/Tests/LibraryTests/LibraryViewModelTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to the bottom of `LibraryViewModelTests.swift` (inside a new `extension LibraryViewModelTests`):

```swift
extension LibraryViewModelTests {
    @Test func isImportingStartsFalse() async {
        let f = Self.makeVM()
        #expect(f.vm.isImporting == false)
    }

    @Test func startImportClearsIsImportingOnSuccess() async {
        let f = Self.makeVM()
        f.importer.preparedPlans = [Self.makePlan()]
        f.importer.commitFactory = { _, _ in Self.makeItem(title: "Imported") }
        await f.vm.startImport(from: URL(filePath: "/tmp/x.mscx"))
        #expect(f.vm.isImporting == false)
    }

    @Test func startImportClearsIsImportingOnDuplicate() async {
        let f = Self.makeVM()
        let existing = Self.makeItem(title: "Existing")
        f.importer.preparedPlans = [Self.makePlan(duplicates: [existing])]
        await f.vm.startImport(from: URL(filePath: "/tmp/x.mscx"))
        #expect(f.vm.duplicatePrompt != nil)
        #expect(f.vm.isImporting == false)
    }

    @Test func startImportClearsIsImportingOnPrepareError() async {
        let f = Self.makeVM()
        f.importer.prepareImportErrors = [.scoreParseFailed(reason: "bad")]
        await f.vm.startImport(from: URL(filePath: "/tmp/x.mscx"))
        #expect(f.vm.errorAlertMessage != nil)
        #expect(f.vm.isImporting == false)
    }

    @Test func commitClearsIsImportingOnSuccess() async {
        let f = Self.makeVM()
        let plan = Self.makePlan()
        f.importer.commitFactory = { _, _ in Self.makeItem(title: "X") }
        await f.vm.commit(plan: plan, decision: .importAsNew)
        #expect(f.vm.isImporting == false)
    }

    @Test func commitClearsIsImportingOnError() async {
        let f = Self.makeVM()
        let plan = Self.makePlan()
        f.importer.commitImportError = .persistenceFailed(reason: "x")
        await f.vm.commit(plan: plan, decision: .importAsNew)
        #expect(f.vm.errorAlertMessage != nil)
        #expect(f.vm.isImporting == false)
    }
}
```

- [ ] **Step 2: Run tests to verify the first one fails (the rest pass since the property doesn't exist yet — they won't compile)**

Run from package directory:
```
cd Packages/Features/Library && swift test --filter isImportingStartsFalse
```

Expected: build failure on `f.vm.isImporting` — property does not exist.

- [ ] **Step 3: Add the `isImporting` property**

In `Packages/Features/Library/Sources/Library/LibraryViewModel.swift`, after the `isPreparingShare` declaration (around line 14), insert:

```swift
    /// True while a file import is in flight (prepare or commit). Driven by
    /// `defer` blocks in `startImport` and `commit` so it clears on success,
    /// duplicate detection, and any thrown error. The App composition root
    /// uses this to show a loading HUD over the whole shell.
    public var isImporting: Bool = false
```

- [ ] **Step 4: Wrap `startImport(from:)` with set/clear**

Find the existing `startImport(from:)` (around line 218) and prepend the two new lines at the top of the function body:

```swift
    public func startImport(from sourceURL: URL) async {
        isImporting = true
        defer { isImporting = false }
        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if scoped { sourceURL.stopAccessingSecurityScopedResource() }
        }
        // … rest of existing body unchanged …
    }
```

Note: Swift's `defer` blocks run in reverse order of declaration. Putting `isImporting = false` first (defer block declared first) means it runs last — after `stopAccessingSecurityScopedResource`. That ordering is correct: the import is "done" only after we've released the scope.

- [ ] **Step 5: Wrap `commit(plan:decision:)` with set/clear**

Find the existing `commit(plan:decision:)` (around line 237) and prepend the two new lines:

```swift
    public func commit(plan: ImportPlan, decision: ImportDecision) async {
        isImporting = true
        defer { isImporting = false }
        do {
            let item = try await importer.commitImport(plan, decision: decision)
            pendingScoreToOpen = item
        } catch {
            errorAlertMessage = describe(error)
        }
    }
```

- [ ] **Step 6: Run all Library tests to verify**

```
cd Packages/Features/Library && swift test
```

Expected: all tests pass, including the six new ones.

- [ ] **Step 7: Commit**

```
git add Packages/Features/Library/Sources/Library/LibraryViewModel.swift Packages/Features/Library/Tests/LibraryTests/LibraryViewModelTests.swift
git commit -m "Add LibraryViewModel.isImporting flag for in-flight import tracking"
```

---

## Task 2: AppShellView — reset navigation when URL arrives

**Files:**
- Modify: `App/AppShellView.swift`

- [ ] **Step 1: Add `resetNavigationForIncomingURL()` private method**

In `AppShellView.swift`, inside `private struct ReadyShell`, add this method just below the existing `saveNavSnapshot()` (around line 112):

```swift
    /// Snap the user back to library root before an incoming-URL import
    /// starts. Called from both the warm-reentry handler and the cold-launch
    /// task so the UI matches the "import in flight" state immediately,
    /// rather than waiting for the import to finish.
    private func resetNavigationForIncomingURL() {
        if horizontalSizeClass == .regular {
            sidebarPath = NavigationPath()
            detailScoreItem = nil
            columnVisibility = .doubleColumn
        } else {
            compactPath = NavigationPath()
        }
    }
```

- [ ] **Step 2: Call `resetNavigationForIncomingURL()` from the warm-reentry handler**

Find the existing `.onChange(of: bootstrap.pendingIncomingURL)` block (around line 178) and modify it:

```swift
        .onChange(of: bootstrap.pendingIncomingURL) { _, newValue in
            // Warm re-entry: a URL arrived while the app was already running.
            // Fire-and-forget so the import isn't tied to the view's task
            // lifecycle — `.task(id:)` would cancel its current body when the
            // slot is cleared, surfacing as a persistenceFailed alert.
            guard newValue != nil,
                  let url = bootstrap.consumePendingIncomingURL() else { return }
            resetNavigationForIncomingURL()
            Task { await libraryVM.startImport(from: url) }
        }
```

- [ ] **Step 3: Call `resetNavigationForIncomingURL()` from the cold-launch handler**

Find the existing `.task` block (around line 172) and modify it:

```swift
        .task {
            // Cold-launch: drain a URL that .onOpenURL queued before this view appeared.
            if let url = bootstrap.consumePendingIncomingURL() {
                resetNavigationForIncomingURL()
                await libraryVM.startImport(from: url)
            }
        }
```

- [ ] **Step 4: Build to verify**

```
xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 16' -skipPackagePluginValidation build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```
git add App/AppShellView.swift
git commit -m "Reset navigation immediately on incoming URL, before import runs"
```

---

## Task 3: Add localization key for the HUD label

**Files:**
- Modify: `App/Resources/Localizable.xcstrings`

- [ ] **Step 1: Add `app.import.loading.label` to the catalog**

Open `App/Resources/Localizable.xcstrings`. Inside the top-level `"strings"` object, insert (alphabetical position is between `app.detail.empty.title` and `app.review.preprompt.message`):

```json
    "app.import.loading.label" : {
      "localizations" : {
        "en" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Opening…"
          }
        },
        "ja" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "開いています…"
          }
        }
      }
    },
```

(Use the U+2026 single-character ellipsis "…", not three dots, to match the project's existing style.)

- [ ] **Step 2: Verify the catalog is valid JSON**

```
python3 -m json.tool App/Resources/Localizable.xcstrings > /dev/null && echo OK
```

Expected: `OK`.

- [ ] **Step 3: Commit**

```
git add App/Resources/Localizable.xcstrings
git commit -m "Add localization for the import loading HUD label"
```

---

## Task 4: AppShellView — `ImportLoadingHUD` overlay

**Files:**
- Modify: `App/AppShellView.swift`

- [ ] **Step 1: Add the `ImportLoadingHUD` private view**

At the bottom of `AppShellView.swift` (after the closing brace of `private struct ReadyShell`), append:

```swift
private struct ImportLoadingHUD: View {
    var body: some View {
        ZStack {
            // Near-invisible tap-capture layer so the user can't reach the
            // library underneath while the import is running.
            Color.black.opacity(0.001)
                .ignoresSafeArea()
                .accessibilityHidden(true)
            VStack(spacing: 16) {
                ProgressView().controlSize(.large)
                Text("app.import.loading.label")
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .accessibilityElement(children: .combine)
        }
        .transition(.opacity)
    }
}
```

- [ ] **Step 2: Attach `.overlay` to `ReadyShell.body`**

Find the `var body: some View {` in `ReadyShell` (around line 114). The body currently ends with the `.onChange(of: detailScoreItem?.id) { _, _ in saveNavSnapshot() }` modifier. Append a new `.overlay` modifier after it:

```swift
        .overlay {
            if libraryVM.isImporting {
                ImportLoadingHUD()
            }
        }
        .animation(.easeInOut(duration: 0.15), value: libraryVM.isImporting)
```

The `.animation(_:value:)` modifier scopes the easing to the `isImporting` flag so the HUD fades in/out smoothly without animating unrelated state changes in the shell.

- [ ] **Step 3: Build to verify**

```
xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 16' -skipPackagePluginValidation build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```
git add App/AppShellView.swift
git commit -m "Show import loading HUD over AppShellView while import is in flight"
```

---

## Task 5: Manual verification

This task confirms the user-visible behaviour. No automated UI test is added — the navigation reset and HUD are too tightly tied to a real Files-app handoff to be worth driving from XCUIApplication. Hand control to the user once the build is on the simulator.

- [ ] **Step 1: Build, install, launch on iPhone simulator**

```
xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 16' -skipPackagePluginValidation -derivedDataPath /tmp/folino-derived build
xcrun simctl install booted /tmp/folino-derived/Build/Products/Debug-iphonesimulator/Folino.app
xcrun simctl launch booted com.KeyNumber.Folino
```

Expected: app launches at library root.

- [ ] **Step 2: Hand off to the user**

Tell the user:

> The build is installed on the booted simulator. Please verify by hand:
> 1. Import a score (any source) so the library has at least 2 scores.
> 2. Open one of them in the Reader.
> 3. From Files.app, AirDrop, or Mail, open a *different* score with folino.
> 4. Confirm: the Reader pops to library root **immediately**, a translucent loading HUD appears over the library, and once the import finishes the new Reader pushes onto the stack.
> 5. Repeat the test on iPad (rotate or use iPad simulator) to confirm the iPad path: detail clears, HUD appears, then new Reader replaces the detail.

If anything looks off (HUD doesn't appear, navigation doesn't reset, animation feels jarring), report back so we can adjust.

- [ ] **Step 3: After user confirms, no further commit needed.** Task 1–4's commits already capture every code change.
