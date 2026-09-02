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
