import AppKit
import Domain
import SwiftUI

/// A zero-size probe that opts its own window into AppKit's native tab bar: a `tabbingIdentifier` shared by every
/// score window, and `tabbingMode = .preferred` so macOS offers tabbing outside full screen too. Place one instance
/// somewhere inside a score window's content — being a view in that window's tree is the handle, exactly as
/// `MacScrollViewAppearanceProbe` (`Reader/Screens/Mac/MacScrollViewAppearance.swift`) and `EffectiveWindowWidthProbe`
/// reach their own AppKit state; there is no SwiftUI-side property to read back.
///
/// **`.preferred` only asks; it does not decide.** Whether a newly opened window actually lands as a tab is governed
/// by the System Settings "Prefer tabs when opening documents" preference, whose default is *In Full Screen Only* —
/// at that default, `openWindow(value:)` still opens a standalone window even with this assist in place. This assist
/// is what raises `tabbingMode` from the automatic default to `.preferred`, which is the most a window can ask for;
/// it cannot override the user's system-wide choice, and this task cannot verify the outcome — it needs a human
/// opening two scores to see whether they tab. See the QA sheet.
struct MacWindowTabAssist: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSView {
        MacWindowTabProbe()
    }

    func updateNSView(_: NSView, context _: Context) {}
}

/// The probe behind `MacWindowTabAssist`. Writes `tabbingIdentifier` / `tabbingMode` once per window, deferred and
/// latched exactly as `MacScrollViewAppearanceProbe.apply` is — see that file's doc comment for the measurement this
/// inherits: writing AppKit window state from inside `updateNSView` re-enters the navigation observer in the same
/// frame and faults `NavigationRequestObserver tried to update multiple times per frame` (2 faults in 7 launches
/// with an immediate write, 0 in 6 without). `viewDidMoveToWindow` runs outside `updateNSView`'s own pass,
/// but the write still has to hop to the next main-queue turn to stay clear of whatever SwiftUI update placed this
/// view in its window in the first place, so it takes the same `DispatchQueue.main.async` detour. `applied` is the
/// same idempotence guard: a re-entrant `viewDidMoveToWindow` (this view briefly leaving and rejoining the same
/// window) must not queue the write twice.
private final class MacWindowTabProbe: NSView {
    /// Shared by every score window, so macOS treats them as one tab group instead of leaving each to its own —
    /// the whole point of this assist.
    static let tabbingIdentifier = NSWindow.TabbingIdentifier("com.KeyNumber.Folino.score")
    private var applied = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, !applied else { return }
        applied = true
        DispatchQueue.main.async { [weak window] in
            window?.tabbingIdentifier = Self.tabbingIdentifier
            window?.tabbingMode = .preferred
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
/// see `MacShellView.detail`), so every score window already drives the same underlying engine; a second window's
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
