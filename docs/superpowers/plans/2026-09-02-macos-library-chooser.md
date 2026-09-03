# macOS Library Chooser Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Mac library a *chooser* — it closes when a score opens, it presents over the score window (full screen included), a second score lands as a tab of the existing score window, and a score window is never empty because the library is shown instead.

**Architecture:** Everything is in `App/Mac/`. A new `MacScoreWindowRegistry` holds weak references to the live score `NSWindow`s plus the one way back to the library; the existing `MacWindowTabAssist` probe becomes that registry's writer — it registers its window, joins it to the frontmost registered score window with `addTabbedWindow(_:ordered:)` (which is what makes open-as-tab the *app's* default rather than a System-Settings coin flip), and on `willClose` unregisters and shows the library when nothing is left. A second, smaller probe gives the library window `.fullScreenAuxiliary` + `.moveToActiveSpace` collection behavior so ⌘O over a full-screen score does not switch Spaces. The two SwiftUI-side changes are one line each: the browser's open closures dismiss the library window, and `MacShellView`'s empty branch closes its own window and opens the library.

**Tech Stack:** SwiftUI (macOS 15 floor), AppKit (`NSWindow` tabbing / collection behavior / `willCloseNotification`), Swift Testing, xcodegen.

**Spec:** `docs/superpowers/specs/2026-09-01-macos-library-window-redesign-design.md` §2.9 (read §2.1, §2.3, §2.7 and §2.8 for the context it revises), and `docs/superpowers/specs/2026-09-02-macos-edit-session-design.md` §3 for the one-window-per-score rule this must not break.

## Global Constraints

- **macOS only.** No iOS or iPadOS behavior changes. `App/Mac` is a source path of the `FolinoMac` target only (`project.yml:154-160`), so nothing here reaches the iOS app.
- **Deployment floor is macOS 15.0** (`project.yml`, every `Package.swift`). macOS-26-only API must be guarded `if #available(iOS 26, macOS 26, *)` — bare `*` does NOT protect macOS.
- **No new user-facing copy.** `mac.menu.showLibrary` and `mac.toolbar.showLibrary` already exist in `App/Resources/Localizable.xcstrings`; `app.detail.empty.title` stays in the catalog because `App/iOS/AppShellView.swift:603` still uses it.
- **One window per score stays true.** `MacWindowScore` is the score id and nothing else; `WindowGroup(for:)` dedupes on it. Nothing in this plan may add a second window or tab for a score that is already open.
- **The `NavigationRequestObserver` write rule.** Never make two SwiftUI state writes from one handler that runs inside a SwiftUI update. `openWindow` / `dismissWindow` count; a plain property write on a plain class does not. See `ImportedScoreOpener.openImportedScore`'s doc comment in `App/Mac/FolinoMacApp.swift` for the measurements.
- **AppKit window writes hop one main-queue turn.** `MacWindowTabAssist`'s existing `DispatchQueue.main.async` + `applied` latch is not decoration — writing `NSWindow` state straight out of `viewDidMoveToWindow` faulted the navigation observer 2 launches in 7. Every new probe copies that shape.
- **Access control:** new symbols get no access modifier. Nothing here is consumed outside the `FolinoMac` target; tests reach internals via `@testable import folino`.
- **Comment reflow budget is 120 columns** (SwiftLint `line_length.warning`).
- **New file in `App/Mac` ⇒ `xcodegen generate`** before building.

## Scope note — one deliberate reading of the spec

§2.9.1 names three open paths: "Double-click / Return / the row's Open item". Those are the browser's `onOpenScore` /
`onOpenInPlaylist` closures, and Task 4 makes exactly those close the library. **Import and the new-score wizard are
NOT in that list and are deliberately left alone**: they route through `LibraryViewModel.pendingScoreToOpen` and
`ImportedScoreOpener`, whose handler runs *inside* a SwiftUI update and whose write-count shape is the one place in
this file with a measured hazard and an explicitly unmeasured workaround. Adding a fourth deferred write there buys a
behavior the spec did not ask for at the cost of the one measurement in the area. The observable result: importing or
creating a score from the browser opens its window and leaves the browser behind it. Flag this to the user at merge.

---

## File Structure

**Create**

- `App/Mac/MacScoreWindowRegistry.swift` — the live score windows (weak), the stored "show the library" action, the
  terminating flag, and the two decisions built on them (`tabHost(excluding:frontToBack:)`,
  `showLibraryIfNoScoreWindowsRemain()`). No AppKit side effects; it only answers questions.
- `App/Mac/MacLibraryWindowPresentation.swift` — the library window's AppKit probe: `.fullScreenAuxiliary` +
  `.moveToActiveSpace` so ⌘O never switches Spaces, and `tabbingMode = .disallowed` so the library can never be
  merged into the score windows' tab group.
- `Tests/FolinoMacTests/MacScoreWindowRegistryTests.swift` — Swift Testing suite over the registry.

**Modify**

- `App/Mac/MacWindowTabAssist.swift` — the probe becomes the registry's writer: register, tab onto the host, and on
  `willClose` unregister and show the library if nothing is left. The representable installs the `showLibrary` action.
- `App/Mac/MacAppDelegate.swift` — sets `isTerminating` so ⌘Q's window teardown does not summon the library.
- `App/Mac/FolinoMacApp.swift` — `MacLibraryWindowContent` gains the presentation probe and the two open closures
  that dismiss the library.
- `App/Mac/MacShellView.swift` — the empty branch closes the window and opens the library instead of drawing
  `ContentUnavailableView`.

**Create (docs)**

- `docs/superpowers/plans/2026-09-02-macos-library-chooser-qa.md` — the hand-QA sheet, written in Task 6.

---

## Task 1: `MacScoreWindowRegistry`

The bookkeeping every other task reads. Pure logic over `NSWindow` references — no window is shown, ordered or
closed here, which is exactly why it is testable.

**Files:**
- Create: `App/Mac/MacScoreWindowRegistry.swift`
- Test: `Tests/FolinoMacTests/MacScoreWindowRegistryTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces, all `@MainActor` on `final class MacScoreWindowRegistry`:
  - `static let shared: MacScoreWindowRegistry`
  - `var showLibrary: (() -> Void)?`
  - `var isTerminating: Bool` (defaults `false`)
  - `var windows: [NSWindow]` (live, registration order)
  - `var isEmpty: Bool`
  - `func register(_ window: NSWindow)`
  - `func unregister(_ window: NSWindow)`
  - `func tabHost(excluding newcomer: NSWindow, frontToBack: [NSWindow]) -> NSWindow?`
  - `func showLibraryIfNoScoreWindowsRemain()`

- [ ] **Step 1: Write the failing tests**

Create `Tests/FolinoMacTests/MacScoreWindowRegistryTests.swift`:

```swift
import AppKit
@testable import folino
import Testing

/// Spec §2.9.3 and §2.9.5: the registry is what knows which score windows exist, so it is what decides which window
/// a newcomer tabs onto and whether closing one leaves the app with no score on screen.
@MainActor
struct MacScoreWindowRegistryTests {
    /// Off-screen and never ordered front, so a unit test never disturbs the host app's window list.
    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true,
        )
        window.isReleasedWhenClosed = false
        return window
    }

    @Test func `registering twice keeps one entry`() {
        let registry = MacScoreWindowRegistry()
        let window = makeWindow()
        registry.register(window)
        registry.register(window)
        #expect(registry.windows.count == 1)
    }

    @Test func `unregister empties the registry`() {
        let registry = MacScoreWindowRegistry()
        let window = makeWindow()
        registry.register(window)
        #expect(!registry.isEmpty)
        registry.unregister(window)
        #expect(registry.isEmpty)
    }

    @Test func `the tab host is the frontmost registered window that is not the newcomer`() {
        let registry = MacScoreWindowRegistry()
        let older = makeWindow()
        let newer = makeWindow()
        let newcomer = makeWindow()
        registry.register(older)
        registry.register(newer)
        // Front-to-back as AppKit would report it: the newcomer is frontmost, `newer` next.
        let host = registry.tabHost(excluding: newcomer, frontToBack: [newcomer, newer, older])
        #expect(host === newer)
    }

    @Test func `an unregistered window is never a tab host`() {
        let registry = MacScoreWindowRegistry()
        let stranger = makeWindow()
        let registered = makeWindow()
        let newcomer = makeWindow()
        registry.register(registered)
        // `stranger` is in front of `registered` but is not a score window — the library, or Settings.
        let host = registry.tabHost(excluding: newcomer, frontToBack: [newcomer, stranger, registered])
        #expect(host === registered)
    }

    @Test func `the first score window has no tab host`() {
        let registry = MacScoreWindowRegistry()
        let newcomer = makeWindow()
        #expect(registry.tabHost(excluding: newcomer, frontToBack: [newcomer]) == nil)
    }

    @Test func `the library is shown when the last score window goes`() {
        let registry = MacScoreWindowRegistry()
        var shown = 0
        registry.showLibrary = { shown += 1 }
        let window = makeWindow()
        registry.register(window)
        registry.showLibraryIfNoScoreWindowsRemain()
        #expect(shown == 0)
        registry.unregister(window)
        registry.showLibraryIfNoScoreWindowsRemain()
        #expect(shown == 1)
    }

    @Test func `quitting does not summon the library`() {
        let registry = MacScoreWindowRegistry()
        var shown = 0
        registry.showLibrary = { shown += 1 }
        registry.isTerminating = true
        registry.showLibraryIfNoScoreWindowsRemain()
        #expect(shown == 0)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```
xcodegen generate
```

```
xcodebuild test -project Folino.xcodeproj -scheme FolinoMac -destination 'platform=macOS' -skipPackagePluginValidation -only-testing:FolinoMacTests/MacScoreWindowRegistryTests
```

Expected: compile failure — `cannot find 'MacScoreWindowRegistry' in scope`.

**If the run reports `hung before establishing connection`, STOP and report it — do not re-run.** That is either a
locked screen or a stuck `testmanagerd`, and repeating the command cannot fix either. Say so and hand it back.

- [ ] **Step 3: Write the implementation**

Create `App/Mac/MacScoreWindowRegistry.swift`:

```swift
import AppKit
import Foundation

/// The live score windows of this process, plus the one way back to the library.
///
/// **Why the shell needs a registry at all.** Three of §2.9's five rules are about *the set of score windows*, not
/// about any one of them: a newly opened score joins the frontmost existing score window as a tab (§2.9.3), closing
/// the last one puts the library on screen (§2.9.5), and a window whose score is gone closes itself and shows the
/// library (§2.9.4). SwiftUI publishes no such set — `WindowGroup(for:)` hands each window its own value and nothing
/// else — and `NSApp.windows` cannot be filtered down to it, because the library, Settings and every AppKit panel are
/// in there too. So the score windows announce themselves, through `MacWindowTabAssist`'s probe.
///
/// **References are weak, and that is not an optimization.** AppKit owns a window's lifetime; a strong reference here
/// would keep a closed window (and the whole SwiftUI tree behind it, `EditorViewModel` included) alive for the life of
/// the process. `unregister` runs from `NSWindow.willCloseNotification` and is the ordinary path; the weak boxes are
/// the backstop for a window that goes away without one.
///
/// **Nothing here touches AppKit state.** It answers questions — who should host a tab, is anything left — and the
/// probe acts on the answers. That is what makes it testable without showing a window.
@MainActor
final class MacScoreWindowRegistry {
    /// The process's one registry. Production code goes through this; a fresh `MacScoreWindowRegistry()` exists so
    /// tests can work against an empty, isolated instance — the same arrangement `MacEditorRegistry` uses.
    static let shared = MacScoreWindowRegistry()

    private final class WeakWindow {
        weak var window: NSWindow?
        init(_ window: NSWindow) { self.window = window }
    }

    private var boxes: [WeakWindow] = []

    /// Opens (or focuses) the library window. Installed by `MacWindowTabAssist`'s `updateNSView` from every score
    /// window, so it is refreshed on every body pass of every score window and is therefore at its freshest exactly
    /// when it is needed: the moment the last score window closes, microseconds after that window's last update.
    ///
    /// It is stored rather than reached for because the callers are AppKit — a `willClose` notification handler has
    /// no SwiftUI environment, and `openWindow` is the only thing that can create the single-instance `Window` scene
    /// when none exists.
    var showLibrary: (() -> Void)?

    /// Set by `MacAppDelegate.applicationShouldTerminate`. ⌘Q closes every window, which would otherwise read as
    /// "the last score window closed" and open the library on the way out of the process.
    var isTerminating = false

    /// The live registered windows, in registration order.
    var windows: [NSWindow] {
        boxes.compactMap(\.window)
    }

    var isEmpty: Bool {
        windows.isEmpty
    }

    func register(_ window: NSWindow) {
        boxes.removeAll { $0.window == nil }
        guard !boxes.contains(where: { $0.window === window }) else { return }
        boxes.append(WeakWindow(window))
    }

    func unregister(_ window: NSWindow) {
        boxes.removeAll { $0.window === window || $0.window == nil }
    }

    /// The window `newcomer` should become a tab of, or `nil` when it is the only score window.
    ///
    /// `frontToBack` is AppKit's own front-to-back ordering (`NSApp.orderedWindows`), passed in rather than read here
    /// so this is a function of its arguments and can be tested. Front-most first is what makes "the score window you
    /// were last looking at" the host rather than whichever window happened to be registered first — the newcomer
    /// itself is frontmost at the moment this is asked, which is why it is excluded by identity.
    ///
    /// The fallback exists because `orderedWindows` omits windows that are not on screen (minimized, or on another
    /// Space): a registered score window that AppKit will not list is still a legal tab host, and tabbing onto it is
    /// better than minting a standalone window the user did not ask for.
    func tabHost(excluding newcomer: NSWindow, frontToBack: [NSWindow]) -> NSWindow? {
        let registered = windows
        for candidate in frontToBack
            where candidate !== newcomer && registered.contains(where: { $0 === candidate }) {
            return candidate
        }
        return registered.first { $0 !== newcomer }
    }

    /// §2.9.5 — no score open means the library is on screen. A no-op while any score window is left, and while the
    /// app is quitting.
    func showLibraryIfNoScoreWindowsRemain() {
        guard !isTerminating, isEmpty else { return }
        showLibrary?()
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```
xcodegen generate
```

```
xcodebuild test -project Folino.xcodeproj -scheme FolinoMac -destination 'platform=macOS' -skipPackagePluginValidation -only-testing:FolinoMacTests/MacScoreWindowRegistryTests
```

Expected: 7 tests, 7 passing. **Report the count, not "tests pass"** — a `-only-testing:` selector that matches
nothing also exits 0.

- [ ] **Step 5: Commit**

```bash
git add App/Mac/MacScoreWindowRegistry.swift Tests/FolinoMacTests/MacScoreWindowRegistryTests.swift
git commit -m "feat(mac): a registry of the live score windows"
```

---

## Task 2: the score-window probe registers, tabs, and shows the library on the last close

Rules §2.9.3 and §2.9.5. The existing probe already owns the one thing needed to do both — an `NSWindow` handle
inside a score window — so it grows into the registry's writer rather than acquiring a sibling.

**Files:**
- Modify: `App/Mac/MacWindowTabAssist.swift` (whole file rewritten below the `MacScorePlayback` section, which is
  untouched)
- Modify: `App/Mac/MacAppDelegate.swift`

**Interfaces:**
- Consumes: `MacScoreWindowRegistry.shared`, `register(_:)`, `unregister(_:)`, `tabHost(excluding:frontToBack:)`,
  `showLibraryIfNoScoreWindowsRemain()`, `showLibrary`, `isTerminating` (Task 1); `MacWindowID.library`
  (`App/Mac/FolinoMacApp.swift`).
- Produces: `MacWindowTabAssist` keeps its name and its call site (`MacShellView.body`'s `.background(...)`), so no
  later task re-wires it.

- [ ] **Step 1: Replace the probe**

In `App/Mac/MacWindowTabAssist.swift`, replace everything from the `import` lines down to (but NOT including) the
`// PARITY(macos): one score plays at a time` comment with:

```swift
import AppKit
import Domain
import SwiftUI

/// A zero-size probe that makes its window a *score window* in the shell's eyes: it joins `MacScoreWindowRegistry`,
/// it opts into AppKit's native tab bar, and it is what tabs a newly opened score onto the score window that is
/// already up. Place one instance somewhere inside a score window's content — being a view in that window's tree is
/// the handle, exactly as `MacScrollViewAppearanceProbe` (`Reader/Screens/Mac/MacScrollViewAppearance.swift`) and
/// `EffectiveWindowWidthProbe` reach their own AppKit state; there is no SwiftUI-side property to read back.
///
/// **`tabbingMode = .preferred` was measured to be not enough, which is why `addTabbedWindow` is here.** `.preferred`
/// only *asks*; whether a newly opened window actually lands as a tab is governed by the System Settings "Prefer tabs
/// when opening documents" preference, whose default is *In Full Screen Only*. The user measured on 2026-09-02 that
/// a second score opened as a separate window **even with the first in full screen**, and found no setting to change
/// — so the ask is not being honored and the app has to place the tab itself (design §2.9.3). `addTabbedWindow(_:
/// ordered:)` is that placement, and it does not consult the preference.
struct MacWindowTabAssist: NSViewRepresentable {
    @Environment(\.openWindow) private var openWindow

    func makeNSView(context _: Context) -> NSView {
        MacScoreWindowProbe()
    }

    /// Refreshes the registry's way back to the library on every body pass of every score window.
    ///
    /// **This is not a SwiftUI state write.** It assigns a closure to a stored property of a plain class, which
    /// invalidates no view and schedules no update — the same reasoning `MacImportedScoreClaim` records, and the
    /// same reason it is safe inside `updateNSView`. It is here rather than in `makeNSView` so the captured
    /// `OpenWindowAction` is always the current one; the moment it is needed is §2.9.5's, one turn after the last
    /// score window's last update, and this is the freshest action the app has at that instant.
    func updateNSView(_: NSView, context _: Context) {
        MacScoreWindowRegistry.shared.showLibrary = { openWindow(id: MacWindowID.library) }
    }
}

/// The probe behind `MacWindowTabAssist`.
///
/// **Every AppKit window write hops one main-queue turn, and that is measured, not stylistic.** It is inherited from
/// `MacScrollViewAppearanceProbe.apply` — see that file's doc comment: writing AppKit window state from inside
/// `updateNSView` re-enters the navigation observer in the same frame and faults `NavigationRequestObserver tried to
/// update multiple times per frame` (2 faults in 7 launches with an immediate write, 0 in 6 without).
/// `viewDidMoveToWindow` runs outside `updateNSView`'s own pass, but the write still has to clear whatever SwiftUI
/// update placed this view in its window, so it takes the same `DispatchQueue.main.async` detour. `applied` is the
/// idempotence guard: a re-entrant `viewDidMoveToWindow` (this view briefly leaving and rejoining the same window)
/// must not queue the work twice.
private final class MacScoreWindowProbe: NSView {
    /// Shared by every score window, so macOS treats them as one tab group instead of leaving each to its own.
    static let tabbingIdentifier = NSWindow.TabbingIdentifier("com.KeyNumber.Folino.score")
    private var applied = false
    private var closeObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, !applied else { return }
        applied = true
        observeClose(of: window)
        // The whole AppKit side, one turn later — see the type's doc comment.
        DispatchQueue.main.async { [weak window] in
            guard let window else { return }
            window.tabbingIdentifier = Self.tabbingIdentifier
            window.tabbingMode = .preferred
            Self.joinExistingScoreWindow(window)
            MacScoreWindowRegistry.shared.register(window)
        }
    }

    /// §2.9.3 — a second score becomes a tab of the score window already on screen, not a window of its own.
    ///
    /// `tabGroup == nil` is the guard against doing it twice: if the system's own preference already tabbed this
    /// window (the "In Full Screen Only" default, with the host in full screen), it arrives with a tab group and
    /// `addTabbedWindow` would only shuffle it. `makeKeyAndOrderFront` after the move is what leaves the *new* score
    /// selected — `addTabbedWindow(_:ordered: .above)` places the tab but does not promise it is the active one.
    private static func joinExistingScoreWindow(_ window: NSWindow) {
        guard window.tabGroup == nil,
              let host = MacScoreWindowRegistry.shared.tabHost(
                  excluding: window, frontToBack: NSApp.orderedWindows,
              )
        else { return }
        host.addTabbedWindow(window, ordered: .above)
        window.makeKeyAndOrderFront(nil)
    }

    /// §2.9.5 — the last score window closing puts the library on screen.
    ///
    /// `willCloseNotification` rather than `viewDidMoveToWindow(nil)` or a SwiftUI `onDisappear`: those fire for view
    /// tree churn as well as for a closing window, and the decision here has to be exactly "this window closed". The
    /// notification arrives on the main queue and the whole registry is `@MainActor`, so `assumeIsolated` is stating
    /// a fact rather than making a promise.
    private func observeClose(of window: NSWindow) {
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main,
        ) { notification in
            guard let closing = notification.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                let registry = MacScoreWindowRegistry.shared
                registry.unregister(closing)
                registry.showLibraryIfNoScoreWindowsRemain()
            }
        }
    }

    deinit {
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
    }
}
```

- [ ] **Step 2: Set the terminating flag**

In `App/Mac/MacAppDelegate.swift`, add one line as the first statement of `applicationShouldTerminate` and extend the
doc comment:

```swift
/// The AppKit lifecycle the Mac shell owns.
///
/// **Flushing**: an edit made within the autosave debounce of ⌘Q must reach the disk. Every window's `onDisappear`
/// flushes on close; quitting the app does not reliably reach those, so termination is deferred until every live
/// editor has flushed (design §2.1).
///
/// **Quitting is not "the last score window closed"**: ⌘Q closes every window, and each close would otherwise run
/// §2.9.5 and summon the library on the way out. The flag is set before the reply is deferred, so it is already true
/// by the time any window closes.
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { MacScoreWindowRegistry.shared.isTerminating = true }
        Task { @MainActor in
            await MacEditorRegistry.shared.flushAll(timeout: .seconds(5))
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
```

If `applicationShouldTerminate` is already `@MainActor`-isolated in this build (AppKit delegate methods usually are),
drop the `MainActor.assumeIsolated` wrapper and write `MacScoreWindowRegistry.shared.isTerminating = true` directly —
whichever compiles cleanly with no warning.

- [ ] **Step 3: Build**

```
xcodegen generate
```

```
Scripts/build-macos-app.sh
```

Expected: `** BUILD SUCCEEDED **`, no new warnings.

- [ ] **Step 4: Re-run the registry tests**

```
xcodebuild test -project Folino.xcodeproj -scheme FolinoMac -destination 'platform=macOS' -skipPackagePluginValidation -only-testing:FolinoMacTests
```

Expected: the whole `FolinoMacTests` bundle green — **state the executed count** (Task 1 added 7 to the 19 that were
there, so 26). `hung before establishing connection` ⇒ stop and report, do not re-run.

- [ ] **Step 5: Commit**

```bash
git add App/Mac/MacWindowTabAssist.swift App/Mac/MacAppDelegate.swift
git commit -m "feat(mac): open a second score as a tab, and show the library when the last one closes"
```

---

## Task 3: the library presents over the score window, full screen included

Rule §2.9.2. A plain `Window` scene summoned while a full-screen window is key can be shown in its own Space, which
switches the user away from the score they are looking at. The fix is AppKit collection behavior, applied by the same
kind of probe Task 2 uses.

**Files:**
- Create: `App/Mac/MacLibraryWindowPresentation.swift`
- Modify: `App/Mac/FolinoMacApp.swift` (`MacLibraryWindowContent.body` only)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `struct MacLibraryWindowPresentation: NSViewRepresentable` — placed as `.background(...)` on the library
  window's content, same as `MacWindowTabAssist` is on the score window's.

- [ ] **Step 1: Write the probe**

Create `App/Mac/MacLibraryWindowPresentation.swift`:

```swift
import AppKit
import SwiftUI

/// Makes the library a *chooser over the score* rather than a window living in a Space of its own (design §2.9.2).
/// Place one instance inside the library window's content; there is no SwiftUI-side equivalent of any of these
/// properties, which is why this is a probe at all.
///
/// Three AppKit facts do the work:
///
/// * **`.fullScreenAuxiliary`** lets this window be shown on top of a full-screen window of the same app instead of
///   forcing a Space switch. Without it, ⌘O from a full-screen score animates the user away from the score they were
///   reading — which is exactly what §2.9.2 forbids.
/// * **`.moveToActiveSpace`** covers the re-summon: a library window that was left open on another Space comes to
///   the Space the user is on, rather than the user being taken to it.
/// * **`tabbingMode = .disallowed`** keeps the library out of the score windows' tab group. They share no tabbing
///   identifier, so AppKit would not merge them on its own — but Window ▸ Merge All Windows does not consult
///   identifiers, and a library folded in as a tab of a score window is a window that cannot then be dismissed
///   independently.
struct MacLibraryWindowPresentation: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSView {
        MacLibraryWindowProbe()
    }

    func updateNSView(_: NSView, context _: Context) {}
}

/// The probe behind `MacLibraryWindowPresentation`. Deferred and latched exactly as `MacWindowTabAssist`'s probe is —
/// see its doc comment for the measurement that makes the `DispatchQueue.main.async` hop mandatory rather than
/// tidy.
private final class MacLibraryWindowProbe: NSView {
    private var applied = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, !applied else { return }
        applied = true
        DispatchQueue.main.async { [weak window] in
            guard let window else { return }
            window.collectionBehavior.insert(.fullScreenAuxiliary)
            window.collectionBehavior.insert(.moveToActiveSpace)
            window.tabbingMode = .disallowed
        }
    }
}
```

- [ ] **Step 2: Apply it**

In `App/Mac/FolinoMacApp.swift`, inside `MacLibraryWindowContent.body`, add the modifier immediately after the
`MacLibraryBrowser(...)` call and before `.focusedSceneValue(...)`:

```swift
        // §2.9.2 — the library is summoned *over* the score window, on the same Space, full screen included.
        .background(MacLibraryWindowPresentation())
```

- [ ] **Step 3: Build**

```
xcodegen generate
```

```
Scripts/build-macos-app.sh
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add App/Mac/MacLibraryWindowPresentation.swift App/Mac/FolinoMacApp.swift
git commit -m "feat(mac): summon the library over the score window, not in another Space"
```

---

## Task 4: opening a score closes the library

Rule §2.9.1, for the three paths the spec names — double-click, Return, and the row's Open item — which are all the
same two closures the browser is handed.

**Files:**
- Modify: `App/Mac/FolinoMacApp.swift` (`MacLibraryWindowContent` only)

**Interfaces:**
- Consumes: `MacWindowID.library`, `MacWindowScore`.
- Produces: nothing later tasks read.

- [ ] **Step 1: Rewrite `MacLibraryWindowContent`**

Replace the whole `private struct MacLibraryWindowContent` in `App/Mac/FolinoMacApp.swift` with:

```swift
/// The library window's content.
///
/// A view rather than inline scene content because it needs a view context: `@Environment(\.openWindow)`,
/// `@Environment(\.dismissWindow)`, the imported-score watcher, and the focused value below all require one.
private struct MacLibraryWindowContent: View {
    let viewModel: LibraryViewModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        MacLibraryBrowser(
            viewModel: viewModel,
            onOpenScore: { openScore($0.id) },
            // PARITY(macos): playlist context in the reader — the `PlaylistID` is dropped here because
            //   `MacWindowScore` carries a score id and nothing else, so `MacReaderRootScreen` opens the score
            //   standalone and the playlist's continuation control and end-of-score auto-advance are unreachable.
            //   Threading a `PlaylistID` through `MacWindowScore` is what closes it. (Moved here from
            //   `MacShellView.sidebar`, which no longer exists — the gap did not close, its call site did.)
            onOpenInPlaylist: { item, _ in openScore(item.id) },
        )
        // §2.9.2 — the library is summoned *over* the score window, on the same Space, full screen included.
        .background(MacLibraryWindowPresentation())
        // The browser has no file importer of its own, so File ▸ Import is the *only* import route while this window
        // is key — and on a fresh launch with an empty library it is the only import route the app has at all.
        // `@FocusedValue` follows scene focus, so a score window publishing this does nothing for the browser; the
        // browser has to publish its own.
        .focusedSceneValue(\.macLibraryImportAction) { url in await viewModel.startImport(from: url) }
            .opensImportedScores(from: viewModel)
    }

    /// §2.9.1 — the library is a chooser: choosing a score opens its window and closes this one, in one gesture.
    ///
    /// **The dismiss is deferred by one main-actor hop, and the open is not.** These closures are reached from
    /// `contextMenu(forSelectionType:primaryAction:)`, from `onKeyPress`, and from a context-menu button — an event
    /// handler in the first two cases, but SwiftUI does not promise that no update is in flight when one runs, and
    /// `ImportedScoreOpener.openImportedScore`'s measurements say two window-scene writes in one such handler are
    /// what faults `NavigationRequestObserver`. Keeping the shape those measurements cover costs one turn of the
    /// library staying up behind the new window, which is invisible.
    ///
    /// **Import and the new-score wizard deliberately do not do this.** §2.9.1 names double-click, Return and the
    /// row's Open item; those routes go through `LibraryViewModel.pendingScoreToOpen` and `ImportedScoreOpener`
    /// instead, whose handler genuinely does run inside an update and whose write count is the one measured hazard
    /// in this file. Importing from the browser leaves the browser behind the new score window.
    private func openScore(_ id: ScoreItem.ID) {
        openWindow(value: MacWindowScore(scoreID: id))
        Task { @MainActor in
            dismissWindow(id: MacWindowID.library)
        }
    }
}
```

- [ ] **Step 2: Build**

```
Scripts/build-macos-app.sh
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add App/Mac/FolinoMacApp.swift
git commit -m "feat(mac): choosing a score closes the library"
```

---

## Task 5: a score window is never empty

Rule §2.9.4. `MacShellView`'s `else` branch is reached when the window's `scoreID` names a row the library holds
neither live nor in the trash (permanently deleted, or a restored window value that outlived its score), and when a
window is minted with no value at all. Today it draws `ContentUnavailableView` **with no toolbar**, so there is not
even a library button to get out with.

**Files:**
- Modify: `App/Mac/MacShellView.swift`

**Interfaces:**
- Consumes: `MacWindowID.library`.
- Produces: nothing later tasks read.

- [ ] **Step 1: Add the dismiss environment value**

In `App/Mac/MacShellView.swift`, beside the existing `@Environment(\.openWindow) private var openWindow`:

```swift
    /// §2.9.4's other half: a score window with no score closes itself. `dismiss()` in the root view of a window
    /// scene closes that window.
    @Environment(\.dismiss) private var dismiss
```

- [ ] **Step 2: Replace the empty branch**

In `content`, replace the whole `} else { ContentUnavailableView { ... } }` branch with:

```swift
        } else {
            // §2.9.4 — a score window never shows an empty state. This is reached when the window's `scoreID` names
            // a row the library holds neither live nor in the trash (permanently deleted, or a restored window value
            // that outlived its score), and when a window is minted with no value at all. The old
            // `ContentUnavailableView` here carried no toolbar, so it was not merely empty — it was a window with no
            // way out but ⌘W.
            //
            // **There is no race with startup.** `FolinoMacApp` builds `MacShellView` only once `bootstrap.isReady`
            // is true, and `AppBootstrap.finishStartup` awaits `repository.refresh()` before setting it — so the
            // rows are loaded by the time `openScoreItem` is asked, and a `nil` here means genuinely absent.
            //
            // Ordering: the library first, then the close. Closing first would leave the app windowless for a turn,
            // and `showLibraryIfNoScoreWindowsRemain` would summon the library anyway — the same window, from a
            // second route. One route, one summons.
            Color.clear
                .task {
                    openWindow(id: MacWindowID.library)
                    dismiss()
                }
        }
```

- [ ] **Step 3: Build**

```
Scripts/build-macos-app.sh
```

Expected: `** BUILD SUCCEEDED **`. `ContentUnavailableView` may now be an unused import-level symbol — it is part of
SwiftUI, so nothing to remove. `app.detail.empty.title` stays in the catalog: `App/iOS/AppShellView.swift:603` uses it.

- [ ] **Step 4: Verify the key is still referenced**

```
grep -rn "app.detail.empty" App Packages Tests
```

Expected: the catalog entry plus `App/iOS/AppShellView.swift` — and no longer `App/Mac/MacShellView.swift`.

- [ ] **Step 5: Commit**

```bash
git add App/Mac/MacShellView.swift
git commit -m "feat(mac): a score window with no score shows the library instead"
```

---

## Task 6: gates and the QA sheet

Nothing in §2.9 can be proved by a machine in this repo — every rule is about windows, Spaces and tabs. The gates
prove nothing regressed; the QA sheet is what the user runs.

**Files:**
- Create: `docs/superpowers/plans/2026-09-02-macos-library-chooser-qa.md`

**Interfaces:**
- Consumes: everything above.
- Produces: the QA sheet the merge decision rests on.

- [ ] **Step 1: Take main's changes, if any**

```
git -C <worktree> merge main
```

Expected: `Already up to date`, or a clean merge. Resolve conflicts before continuing.

- [ ] **Step 2: Run the macOS package gate**

```
Scripts/build-macos-packages.sh
```

Expected: every package green. State how many packages it built.

- [ ] **Step 3: Run the Mac app build**

```
Scripts/build-macos-app.sh
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Run the Mac test bundle**

```
xcodebuild test -project Folino.xcodeproj -scheme FolinoMac -destination 'platform=macOS' -skipPackagePluginValidation -only-testing:FolinoMacTests
```

Expected: 26 tests executed, 26 passing. **State the count.** `hung before establishing connection` ⇒ stop and report
(locked screen or stuck `testmanagerd`); do not re-run the same command.

- [ ] **Step 5: Run the Reader package tests**

From `Packages/Features/Reader` (two Bash calls — `cd` first, then the bare command):

```
cd <worktree>/Packages/Features/Reader
```

```
xcodebuild test -scheme Reader-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.5' -skipPackagePluginValidation
```

Expected: the suite green. State the count. Reader is untouched by this plan, so this is a regression check on the
merge in Step 1, not on the feature.

- [ ] **Step 6: Write the QA sheet**

Create `docs/superpowers/plans/2026-09-02-macos-library-chooser-qa.md`:

```markdown
# macOS library chooser — QA

Spec: `docs/superpowers/specs/2026-09-01-macos-library-window-redesign-design.md` §2.9
Plan: `docs/superpowers/plans/2026-09-02-macos-library-chooser.md`

Build **Debug** for everything here — none of it plays audio. (Playback QA needs Release; see the
`feedback_macos_qa_release_build` memory.)

## Section A — the five rules

| # | Steps | Expected |
| --- | --- | --- |
| 1 | Launch with the library up. Double-click a score. | The score window opens **and the library window closes**, one gesture. |
| 2 | Same, but select a row and press Return. | Same as 1. |
| 3 | Same, but use the row's context-menu Open. | Same as 1. |
| 4 | With a score window up, click the toolbar's library button. | The library appears **in front of the score window, on the same Space**. No Space switch, no bounce. |
| 5 | Same, with ⌘O. | Same as 4. |
| 6 | Put the score window in **full screen**. Press ⌘O. | The library appears **over the full-screen score**, still in full screen. The Mac does **not** animate to another Space. |
| 7 | From 6's library, double-click a second score. | The library closes; the second score is a **new tab of the same full-screen window**, and it is the selected tab. |
| 8 | Not in full screen: with one score open, ⌘O then double-click a second score. | The second score is a **new tab** of the existing window — not a separate window. The tab bar appears. |
| 9 | Open a third score the same way. | Three tabs, one window. |
| 10 | ⌘W the last score window (close every tab). | The **library appears**. The app does not quit and does not sit with no windows. |
| 11 | With the library up and no score window, ⌘W the library. | The library closes. The app stays running with no window (Dock icon still there); clicking the Dock icon or ⌘O brings the library back. |
| 12 | Open a score. In the library (⌘O), permanently delete that same score from Recently Deleted, then look at the score window. | The score window **closes itself** and the library is on screen. No `ContentUnavailableView`, no toolbar-less window. |
| 13 | Open a score, ⌘Q. | The app quits. **No library window flashes up on the way out.** |
| 14 | Open score A. From the library open score B. From the library open A again. | A's existing tab comes forward; there is no second tab or window for A (§2.3 revision — this must not have regressed). |

## Section B — what this slice deliberately did not change

| # | Steps | Expected |
| --- | --- | --- |
| 15 | With the library up, File ▸ Import (⇧⌘I) a new file. | The score opens in a window. **The library stays open behind it** — import is not one of §2.9.1's three named open paths. Confirm this is the behavior you want; the alternative is a one-line change in `ImportedScoreOpener`. |
| 16 | With the library up, use `+` ▸ New Score. | Same as 15. |
| 17 | With a score window key and the library closed, ⇧⌘I a file already in the library. | The library is summoned and presents the duplicate prompt (`MacShellView.importAction`, unchanged). |

## Section C — the fault check (re-measured, per spec §5.3)

Open Console.app, filter `NavigationRequestObserver`. Then, in one run:

1. Import a file (⇧⌘I).
2. Double-click a row.
3. ⌘-click a second row.
4. ⇧-click a third row.
5. ⌫ on the selection.
6. Open a second score so it tabs.
7. ⌘W the last score window.

Expected: **no** `Update NavigationRequestObserver tried to update multiple times per frame` lines. One is a
regression. The positive control: the fault is real and observable — if you cannot make it appear at all in any app
state, the filter is wrong, not the app.

## Section D — if a rule fails

- **6 switches Spaces anyway.** The next lever is `window.level = .floating` in
  `MacLibraryWindowProbe`, on top of `.fullScreenAuxiliary`. Failing that, the spec's own fallback is a real
  `NSPanel` (`.nonactivatingPanel`) for the library.
- **7 or 8 opens a separate window.** Log `MacScoreWindowRegistry.shared.windows.count` and the `tabHost` result
  inside `joinExistingScoreWindow`. A `nil` host means registration is racing the open (the deferred `register` runs
  after the newcomer's `tabHost` query); a non-nil host that does not tab means `addTabbedWindow` is being refused,
  and `window.tabGroup` before/after is the thing to print.
- **10 does nothing.** The stored `showLibrary` action is stale — print inside the closure to see whether it is being
  called at all. If it is called and nothing opens, the captured `OpenWindowAction` did not survive its window; the
  fix is to install the action from the library window's own probe too, and from `MacCommands`.
- **13 flashes the library.** `isTerminating` is being set too late; move it into `applicationWillTerminate` as well.
```

- [ ] **Step 7: Commit**

```bash
git add docs/superpowers/plans/2026-09-02-macos-library-chooser.md docs/superpowers/plans/2026-09-02-macos-library-chooser-qa.md
git commit -m "docs(mac): the library-chooser plan and its QA sheet"
```

---

## Self-review notes

**Spec coverage.** §2.9.1 → Task 4 (with the import/wizard carve-out argued in the Scope note and put on the QA sheet
as Section B). §2.9.2 → Task 3. §2.9.3 → Task 2's `joinExistingScoreWindow`. §2.9.4 → Task 5. §2.9.5 → Task 2's
`observeClose` plus Task 1's `showLibraryIfNoScoreWindowsRemain`. "What this does NOT change" — one window per score
is untouched (`MacWindowScore` is not edited; QA 14 guards it), playback takeover and global display mode are
untouched, and the browser keeps its sources and bulk actions (`MacLibraryBrowser` is not edited at all).

**Type consistency.** `tabHost(excluding:frontToBack:)`, `showLibraryIfNoScoreWindowsRemain()`, `showLibrary`,
`isTerminating`, `register(_:)`, `unregister(_:)`, `windows`, `isEmpty` are spelled identically in Task 1's
implementation, Task 1's tests and Task 2's call sites. `MacWindowTabAssist` keeps its name so `MacShellView.body`'s
`.background(MacWindowTabAssist())` needs no edit; only the probe class behind it is renamed
(`MacWindowTabProbe` → `MacScoreWindowProbe`), and it is `private`, so nothing outside the file refers to it.

**Known unmeasured spots**, all on the QA sheet with a Section D recovery: `.fullScreenAuxiliary` over a full-screen
window, `addTabbedWindow` into a full-screen window, and the lifetime of a stored `OpenWindowAction` after its window
closes.
