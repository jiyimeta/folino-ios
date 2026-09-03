import AppKit
import Domain
import SwiftUI

/// Whether a newly opened score window still has to be moved into the existing score window's tab group.
///
/// **This exists because the obvious test — `window.tabGroup == nil` — is wrong, and wrong in a way that silently
/// disabled §2.9.3 entirely.** Measured on 2026-09-03 with `os_log` instrumentation in
/// `MacScoreWindowProbe.joinExistingScoreWindow`, opening a second score with one already open:
///
/// ```
/// join: registry=2 ordered=3 host=found hostID=com.KeyNumber.Folino.score tabbingMode=1
/// join: BAILED before addTabbedWindow
/// ```
///
/// The host was found, the tabbing identifiers matched, and the join was skipped anyway — so the only guard left
/// was the `tabGroup` one. **A window is put into a tab group of its own, containing just itself, as soon as it
/// participates in tabbing**, and the line right before the guard sets `tabbingMode = .preferred`, which is exactly
/// that. So `tabGroup` was never `nil`, `addTabbedWindow` was never called once, and every score after the first
/// opened as a standalone window — the precise symptom the user reported on 2026-09-02 and again on 2026-09-03.
///
/// The question the guard actually wants to ask is not "is this window in a tab group" but "is it already in the
/// HOST's tab group" — which is the only case where there is nothing left to do.
@MainActor
enum MacScoreWindowTabbing {
    static func needsJoining(_ window: NSWindow, host: NSWindow) -> Bool {
        guard let group = window.tabGroup else { return true }
        return group !== host.tabGroup
    }
}

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
///
/// **`isScoreWindow` is why this is a parameter rather than a fact of placement.** `MacShellView` applies the assist
/// to its whole body — outside the `if let item` fork — so a window with no score (⌘N, or a restored window naming a
/// score that has since been deleted) hosts one of these too. Such a window must do *none* of this: registering it
/// would tab it into the real score window's group and steal its focus a moment before it dismisses itself, so the
/// user sees a tab flicker in and out and loses the score's focus with it. So the empty case opts out entirely
/// rather than being placed elsewhere.
struct MacWindowTabAssist: NSViewRepresentable {
    /// False for a window with no score. See the type's doc comment: an empty window does nothing here at all.
    let isScoreWindow: Bool

    @Environment(\.openWindow) private var openWindow

    func makeNSView(context _: Context) -> NSView {
        MacScoreWindowProbe(isScoreWindow: isScoreWindow)
    }

    /// Refreshes the registry's way back to the library on every body pass of every score window.
    ///
    /// **This is not a SwiftUI state write.** It assigns a closure to a stored property of a plain class, which
    /// invalidates no view and schedules no update — the same reasoning `MacImportedScoreClaim` records, and the
    /// same reason it is safe inside `updateNSView`. It is here rather than in `makeNSView` so the captured
    /// `OpenWindowAction` is always the current one; the moment it is needed is §2.9.5's, one turn after the last
    /// score window's last update, and this is the freshest action the app has at that instant.
    ///
    /// An empty window installs nothing: it is about to close itself, and the app's stored way back to the library
    /// must not be an action captured by a window that will be gone a turn later.
    func updateNSView(_: NSView, context _: Context) {
        guard isScoreWindow else { return }
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

    /// False for a window with no score — such a window does nothing here at all. See `MacWindowTabAssist`.
    private let isScoreWindow: Bool
    private var applied = false
    private var closeObserver: NSObjectProtocol?
    /// The frame this window has to end up with — the score window it joined as a tab. Non-nil only while the
    /// The frame this window has to end up with — the score window it joined as a tab. Non-nil only while the
    /// correction still has to run, and while it is non-nil the window is deliberately not the selected tab. See
    /// `restoreHostGeometry`.
    private var adoptedFrame: NSRect?

    init(isScoreWindow: Bool) {
        self.isScoreWindow = isScoreWindow
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("not used")
    }

    /// **`viewWillMove`, not `viewDidMoveToWindow`, and synchronous, not deferred — because the tab has to be placed
    /// before the window is ever shown.** Deferring it by one main-queue turn worked (the score did land as a tab)
    /// but the window was *ordered on screen first* and moved afterwards, which the user measured on 2026-09-03 as
    /// a second window flashing into view — and, with the host in full screen, macOS giving that flash its own
    /// Space and leaving a black, empty full-screen Space behind after the window was reparented. `viewWillMove` is
    /// the earliest hook a view has on its window, and doing the work here means AppKit places the tab as part of
    /// bringing the window up rather than as a correction to it.
    ///
    /// This is the one place that deliberately does NOT take `MacScrollViewAppearanceProbe`'s
    /// `DispatchQueue.main.async` detour, and the trade is explicit: that detour exists to keep AppKit window writes
    /// out of a running SwiftUI update (measured: `NavigationRequestObserver tried to update multiple times per
    /// frame`, 2 faults in 7 launches with an immediate write from `updateNSView`, 0 in 6 without). Here the write
    /// MUST be synchronous or the visible artifact returns, so the fault check moves to the QA sheet's Section C
    /// instead of being designed out.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        guard isScoreWindow, let window = newWindow, !applied else { return }
        applied = true
        observeClose(of: window)
        // Registration has to be synchronous with the close observer regardless of anything above: split apart, a
        // window closing in the gap would unregister nothing and then be registered after it is already gone, with
        // its observer token already consumed — a stale entry nothing can ever remove, so `isEmpty` lies for the
        // rest of the session and §2.9.5 never fires again. `joinExistingScoreWindow` excludes the newcomer by
        // identity, so registering first cannot make a window tab onto itself.
        MacScoreWindowRegistry.shared.register(window)
        window.tabbingIdentifier = Self.tabbingIdentifier
        window.tabbingMode = .preferred
        adoptedFrame = Self.joinExistingScoreWindow(window)
    }

    /// Puts the group back on the host's frame after SwiftUI and AppKit have both had their say — see
    /// `restoreHostGeometry`.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        restoreHostGeometry()
    }

    /// Restores the score window's own geometry after joining a tab, and only then shows the new tab.
    ///
    /// **The correction cannot be avoided, so it is hidden instead — and that is the whole design of this method.**
    /// Joining perturbs the newcomer's frame twice: SwiftUI sizes the window from its content after `viewWillMove`,
    /// and AppKit shifts the origin by (+29, −29) a turn after that. Every hook an `NSViewRepresentable` has runs
    /// before SwiftUI settles a `WindowGroup` window's placement, so writing the frame early is a race this loses.
    /// What breaks the race is not writing sooner but **showing later**: a tab group is drawn at its SELECTED tab's
    /// geometry, so while the newcomer stays unselected the group keeps rendering the host's tab at the host's own
    /// frame, and the frames in which the newcomer is wrong are never composited. The selection at the end is
    /// therefore load-bearing, not a tidy-up — move it earlier and the user sees the window jump (measured
    /// 2026-09-03, twice).
    ///
    /// Two writes, because each catches one of the two perturbations: the first the content-driven resize, the
    /// deferred one the origin shift.
    ///
    /// **What was measured and rejected**, so the next person does not re-run it:
    ///
    /// * `setFrame` before `addTabbedWindow`: no trace at all — the join aligns the newcomer's top-left to the
    ///   host's and keeps its own size, discarding the write.
    /// * `.defaultWindowPlacement` on the score `WindowGroup` (macOS 15's own answer to "where is this window
    ///   born"): the size arrives correctly, but the join then grows the window by the tab bar's height and the
    ///   position ends up wrong and STAYS wrong — worse than wrong-then-corrected, because nothing corrects it.
    /// * `NSWindowController.shouldCascadeWindows = false`: no effect. The controller is real and per-window —
    ///   SwiftUI gives each window its own — so this is not the single-controller trap `christiantietze.de`
    ///   documents for hand-rolled tabbing, and the 1:1 fix it prescribes is already in place.
    /// * `NSWindowTabGroup.addWindow` in place of `addTabbedWindow`: identical behavior. (The group form is kept
    ///   where a group already exists, because it says what is meant.)
    ///
    /// The structural alternative — building the second and later tabs' windows with a hand-rolled
    /// `NSWindowController` + `NSHostingController` instead of `openWindow(value:)` — would remove the race rather
    /// than hide it, at the cost of re-implementing `WindowGroup(for:)`'s value dedupe (§2.3's "opening an
    /// already-open score brings its window forward"), scene restoration, and the `focusedSceneValue` menu wiring.
    /// Not worth it while this is invisible; it is the fallback if a future macOS changes the timing.
    private func restoreHostGeometry() {
        guard let window, let adoptedFrame else { return }
        window.setFrame(adoptedFrame, display: false)
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, let adoptedFrame = self.adoptedFrame else { return }
            window.setFrame(adoptedFrame, display: false)
            window.tabGroup?.selectedWindow = window
            window.makeKeyAndOrderFront(nil)
            self.adoptedFrame = nil
        }
    }

    /// §2.9.3 — a second score becomes a tab of the score window already on screen, not a window of its own.
    ///
    /// `MacScoreWindowTabbing.needsJoining` is the guard against doing it twice — and read that type's doc comment
    /// before touching it, because the obvious `tabGroup == nil` test was measured to disable this method outright.
    /// `makeKeyAndOrderFront` after the move is what leaves the *new* score selected — `addTabbedWindow(_:ordered:
    /// .above)` places the tab but does not promise it is the active one.
    /// Returns the frame the window has to be corrected back to, or `nil` when there is nothing to correct — it
    /// joined nothing, or the host is full screen and the group's geometry is the screen's rather than a windowed
    /// rect to inherit. Full screen needs no correction and is measurably correct without one.
    private static func joinExistingScoreWindow(_ window: NSWindow) -> NSRect? {
        guard let host = MacScoreWindowRegistry.shared.tabHost(
            excluding: window, frontToBack: NSApp.orderedWindows,
        ),
            MacScoreWindowTabbing.needsJoining(window, host: host)
        else { return nil }
        let hostFrame = host.frame
        // `NSWindowTabGroup.addWindow` when the host already has a group, `addTabbedWindow` only to create one. The
        // two were measured to behave identically here (2026-09-03); the group form is preferred because it says
        // what is meant — join an existing group — rather than asking AppKit to form one that already exists.
        if let group = host.tabGroup {
            group.addWindow(window)
        } else {
            host.addTabbedWindow(window, ordered: .above)
        }
        // **Deliberately NOT selected here.** A tab group is drawn at its SELECTED tab's geometry, so as long as the
        // newcomer stays unselected the group keeps showing the host's tab at the host's own frame — and the frames
        // in which the newcomer's geometry is still wrong are never composited. Selection happens in
        // `restoreHostGeometry`, after the last correction. A full-screen host needs no correction, so there is
        // nothing to wait for and it is selected immediately.
        if host.styleMask.contains(.fullScreen) {
            window.makeKeyAndOrderFront(nil)
            return nil
        }
        return hostFrame
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

    isolated deinit {
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
    }
}

// PARITY(macos): one score plays at a time — `MacScorePlayback.takeOver(from:)` below is defined but nothing calls
//   it. The play action lives in `Packages/Features/Reader/Sources/Reader/Screens/Mac/MacTransportBar.swift`, whose
//   button calls `viewModel.togglePlayback()` directly; reaching it from `App/Mac` would mean threading a closure
//   through `MacReaderRootScreen` into `ReaderViewModel` — a cross-Feature seam this branch deliberately did not
//   invent. `bootstrap.playbackController` is one shared instance handed to every score window, so two score
//   windows both drive the same engine, but neither window's own transport UI is told when the other takes over.

/// Stops whatever score is currently sounding before another score window starts a new one, so "one score plays at a
/// time" holds even though nothing stops two windows from both showing a transport bar.
///
/// The Mac app builds exactly one `LivePlaybackController` per launch (`AudioStackFactory.make`, wired once by
/// `AppBootstrap.start()` and handed to every window's `MacReaderRootScreen` through `bootstrap.playbackController` —
/// see `MacShellView.content`), so every score window already drives the same underlying engine; a second window's
/// `load` already displaces whatever the first was playing at the engine level. What it does not do on its own is
/// leave the first window's own transport UI in a state that agrees with that — its `ReaderPlaybackSession` still
/// believes it is playing until something tells it otherwise. `takeOver` is that something: it calls the one member
/// `Domain.PlaybackController` exposes for stopping a running transport,
/// `pause() async` (`Packages/Domain/Sources/Domain/Protocols/PlaybackController.swift:22`) — there is no separate
/// "stop", and `Domain` has no `PlaybackControlling` protocol, only `PlaybackController`.
@MainActor
enum MacScorePlayback {
    static func takeOver(from controller: any PlaybackController) async {
        await controller.pause()
    }
}
