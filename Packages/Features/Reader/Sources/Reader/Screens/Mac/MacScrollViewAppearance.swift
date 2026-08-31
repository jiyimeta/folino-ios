#if os(macOS)
import AppKit
import SwiftUI

/// Pins the `NSScrollView` enclosing this view — and nothing above it — to a fixed appearance.
///
/// **It exists for the scroller knob, which is the one semantic element that rides on the reader's paper.** Vertical
/// mode paints `MacReaderGround.paper` across the whole scroll view, edge to edge, the way the iOS reader does; AppKit
/// draws its overlay scroller *inside* that frame, so on a dark-appearance Mac a light knob slides over white paper
/// and is invisible. Everything else the reader draws is either a concrete colour (the engraving, the ink, a PDF page)
/// or stands on the ground rather than the paper (page numbers, spinners, the failure panel) — see
/// `MacReaderRootScreen`. The scroller is the exception, and this is the exception's fix.
///
/// **Scoped by construction, which is the whole point.** `preferredColorScheme` was removed from this reader
/// precisely because on macOS it lands on the window's `NSAppearance` and takes the library column with it. Setting
/// `appearance` on one `NSScrollView` cannot escape that scroll view: its subtree is the hosted score content, whose
/// colours are concrete anyway, and the window keeps reporting whatever the system is set to. This is the AppKit
/// analogue of the trait override `hostingAppearance(_:)` performs on iOS, narrowed to the one view that needs it.
///
/// Applied only while there is a laid-out document to show — see the call site. Before that the surface paints no
/// paper, so the spinner standing on the window's own ground must keep the system appearance or it would be a dark
/// spinner on a dark ground.
struct MacScrollViewAppearance: NSViewRepresentable {
    let appearance: NSAppearance.Name

    func makeNSView(context _: Context) -> NSView {
        MacScrollViewAppearanceProbe(appearance)
    }

    func updateNSView(_ nsView: NSView, context _: Context) {
        (nsView as? MacScrollViewAppearanceProbe)?.apply(appearance)
    }
}

/// A zero-size view whose only job is to sit inside the scroll view's document view, so `enclosingScrollView` can walk
/// up to the scroll view itself. There is no SwiftUI-side handle on it; being a view in its tree is the handle — the
/// same trick `HostingAppearanceProbe` plays with the responder chain on iOS.
private final class MacScrollViewAppearanceProbe: NSView {
    private var name: NSAppearance.Name
    /// Weak, and remembered rather than re-derived: the override has to come off the scroll view it was put on, which
    /// is not necessarily the one `enclosingScrollView` would answer with at teardown time.
    private weak var pinned: NSScrollView?
    /// What has already been scheduled onto `pinned`, so a re-entrant `updateNSView` does not queue it again.
    private var applied: NSAppearance.Name?

    init(_ name: NSAppearance.Name) {
        self.name = name
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("MacScrollViewAppearanceProbe is never loaded from a nib")
    }

    /// The scroll view is only reachable once this view is in a window — and leaving one is the cue to hand the
    /// appearance back, in case AppKit recycles the scroll view for content that wants none.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            release()
        } else {
            apply(name)
        }
    }

    /// **Deferred, and idempotent, and both are load-bearing.**
    ///
    /// `updateNSView` runs inside a SwiftUI update, and writing `NSScrollView.appearance` there re-enters the split
    /// view's navigation observer in the same frame — the same `NavigationRequestObserver` fault
    /// `MacShellView.openImportedScore` documents at length, and it was measured here: 2 faults in 7 launches with an
    /// immediate write, 0 in 6 without the probe at all. Hopping to the next main-queue callout takes the write out
    /// of the pass, and the guard means a scroll or a playback tick — both of which re-run `updateNSView` — does not
    /// re-write an appearance that is already set.
    ///
    /// A one-callout delay is invisible here: the overlay scroller is not on screen at the instant the score lands.
    func apply(_ name: NSAppearance.Name) {
        self.name = name
        guard window != nil, let scrollView = enclosingScrollView else { return }
        guard pinned !== scrollView || applied != name else { return }
        if pinned !== scrollView {
            release()
            pinned = scrollView
        }
        // Recorded now, not in the block: `updateNSView` can run again before the callout lands, and without this the
        // write would be queued once per intervening scroll frame.
        applied = name
        DispatchQueue.main.async { [weak scrollView] in
            scrollView?.appearance = NSAppearance(named: name)
        }
    }

    private func release() {
        // `nil`, not a concrete appearance: that is what lets the scroll view inherit from its window again.
        pinned?.appearance = nil
        pinned = nil
        applied = nil
    }
}
#endif
