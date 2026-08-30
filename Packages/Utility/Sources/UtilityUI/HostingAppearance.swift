import SwiftUI

#if os(iOS)
import UIKit
#endif

extension View {
    /// Pins this screen — and only this screen — to a light or dark appearance, by overriding the traits of the view
    /// controller that hosts it.
    ///
    /// Use this instead of `preferredColorScheme` for a screen whose CONTENT is a fixed colour, such as the Reader's
    /// always-white paper. The two differ in scope, and the scope is the whole reason this exists:
    ///
    /// * `preferredColorScheme` travels up as a preference and is applied at the **window scene's** trait overrides.
    ///   Measured, not assumed: with it in force on a device set to dark, the scene, the window and `\.colorScheme` at
    ///   every level all reported `light` — including *above* the screen that asked for it. Two consequences follow.
    ///   Popping back leaves the destination pinned until the pop animation ends, so the library slid in white for the
    ///   length of the transition. And nothing inside the app could still report what the OS was actually set to, so a
    ///   sheet that wanted to opt back out had no value to opt back out *to*.
    /// * `traitOverrides` on a view controller covers that controller's subtree and nothing else. A sibling still on
    ///   the navigation stack keeps the system appearance throughout the transition, sheets presented from the screen
    ///   come up in the system appearance on their own (verified on device — they need no counter-measure), and the
    ///   window scene keeps reporting the truth.
    ///
    /// It also reaches further DOWN than the SwiftUI equivalent. `.environment(\.colorScheme, .light)` stops at the
    /// SwiftUI tree, leaving UIKit content hosted inside it — `PKCanvasView`, which inverts ink for a dark trait, and
    /// the score's scroll host — on the system appearance. A trait override is what those read.
    ///
    /// The status bar comes along too: `UIHostingController` resolves its `.default` style against its own trait
    /// collection, so a pinned screen gets dark status-bar content over its white page while the rest of the app keeps
    /// whatever the OS is set to. That is the one thing no public SwiftUI API can scope to a single screen, and it is
    /// why the alternatives were rejected.
    ///
    /// **A navigation bar is NOT covered**: it belongs to the enclosing `UINavigationController`, which is this
    /// controller's parent, and trait overrides do not travel upward. Pair this with
    /// `.toolbarColorScheme(_:for: .navigationBar)` on the same screen.
    ///
    /// On macOS this is a no-op: the Mac shell has no per-screen appearance scoping yet.
    @ViewBuilder
    public func hostingAppearance(_ scheme: ColorScheme) -> some View {
        #if os(iOS)
        background(
            HostingAppearanceApplier(style: scheme == .dark ? .dark : .light)
                .allowsHitTesting(false)
                .accessibilityHidden(true),
        )
        #else
        self
        #endif
    }
}

// PARITY(macos): per-screen light/dark scoping — macOS would set NSAppearance on the hosting view instead of
// UITraitOverrides.

#if os(iOS)
private struct HostingAppearanceApplier: UIViewRepresentable {
    let style: UIUserInterfaceStyle

    func makeUIView(context _: Context) -> HostingAppearanceProbe {
        HostingAppearanceProbe(style: style)
    }

    func updateUIView(_ view: HostingAppearanceProbe, context _: Context) {
        view.apply(style)
    }
}

/// A zero-size view whose only job is to sit inside the hosted hierarchy, so the responder chain above it can be
/// walked up to the controller that owns the screen. There is no SwiftUI-side handle on that controller; being a view
/// in its tree is the handle.
private final class HostingAppearanceProbe: UIView {
    private var style: UIUserInterfaceStyle
    /// Weak, and remembered rather than re-derived: the override has to be taken back off the controller it was put
    /// on, which is not necessarily the one the responder chain would answer with at teardown time.
    private weak var pinned: UIViewController?

    init(style: UIUserInterfaceStyle) {
        self.style = style
        super.init(frame: .zero)
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("HostingAppearanceProbe is never loaded from a nib")
    }

    /// The controller is only reachable once this view is in a window — and leaving one is the cue to hand the
    /// appearance back, in case SwiftUI recycles the controller for a screen that wants no pin.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            release()
        } else {
            apply(style)
        }
    }

    func apply(_ style: UIUserInterfaceStyle) {
        self.style = style
        guard window != nil, let controller = owningController else { return }
        if pinned !== controller {
            release()
            pinned = controller
        }
        controller.traitOverrides.userInterfaceStyle = style
        // The status bar is not recomputed by the trait change alone.
        controller.setNeedsStatusBarAppearanceUpdate()
    }

    private func release() {
        guard let pinned else { return }
        // `remove`, not `.unspecified`: `traitOverrides` distinguishes "no override" from "overridden to unspecified",
        // and only the former lets the controller inherit again.
        pinned.traitOverrides.remove(UITraitUserInterfaceStyle.self)
        pinned.setNeedsStatusBarAppearanceUpdate()
        self.pinned = nil
    }

    private var owningController: UIViewController? {
        var responder: UIResponder? = next
        while let current = responder {
            if let controller = current as? UIViewController {
                return controller
            }
            responder = current.next
        }
        return nil
    }
}
#endif
