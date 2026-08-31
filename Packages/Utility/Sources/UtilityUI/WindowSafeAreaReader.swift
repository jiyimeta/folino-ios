import SwiftUI

#if os(iOS)
import UIKit
#endif

extension EnvironmentValues {
    /// Pins what `onWindowTopSafeAreaChange` reports, instead of reading the window's own inset. `nil` — the default,
    /// and the only value a running app ever wants — reads the window.
    ///
    /// Set by the **screenshot harness**, which lays a screen out inside a mock device frame that is not the window.
    /// Reading the window there is a category error: the frame draws no status-bar band, so a screen that positions
    /// something inside the top safe area (the Reader's cutout tier) puts it on top of its own control strip instead
    /// of above it. Pinned to 0, the screen sees the truth about the surface it is actually drawn on.
    @Entry public var windowTopSafeAreaInsetOverride: CGFloat?
}

extension View {
    /// Reports the **window's** top safe-area inset — the band the system reserves for the status bar and the display
    /// cutout — and keeps reporting it as it changes (rotation, a Dynamic Island activity growing, a resize).
    ///
    /// Use this instead of reading `safeAreaInsets.top` from a SwiftUI geometry proxy whenever the screen doing the
    /// reading also **adds** to its own safe area, e.g. with `safeAreaInset(edge: .top)`. A proxy is measured inside
    /// the modified view, so once the inset is attached it reports the system's band PLUS the strip the screen just
    /// added — and if the strip's height is derived from the reading, the two chase each other upward. Measured on an
    /// iPhone 16 Pro: 62 (correct) then 114 then 122, converging on a value with the strip counted twice, which made a
    /// 62pt cutout band render 122pt tall over the row below it.
    ///
    /// The window's insets have no such loop: they are the device's, they belong to a layer above anything a screen
    /// can add, and a screen embedded in a smaller container still reads the truth rather than its container's
    /// leftovers. The one case where that is the wrong answer — a container standing in for a whole device — pins the
    /// value with `\.windowTopSafeAreaInsetOverride` instead.
    ///
    /// On macOS this is not implemented yet — it is a no-op there, not a statement that macOS windows lack a top
    /// safe-area inset (`NSWindow`/`NSView` have exposed one since macOS 11, and a full-screen window on a notched
    /// display reports a real value).
    @ViewBuilder
    public func onWindowTopSafeAreaChange(_ action: @escaping (CGFloat) -> Void) -> some View {
        #if os(iOS)
        modifier(WindowTopSafeAreaChange(action: action))
        #else
        self
        #endif
    }
}

// PARITY(macos): window top safe-area probe — macOS needs an NSView/NSWindow-backed equivalent that reads
//   `NSWindow.contentView?.safeAreaInsets.top` before any Mac screen can report it.

#if os(iOS)
/// Reports the window's top inset, unless `\.windowTopSafeAreaInsetOverride` pins one. A modifier rather than a bare
/// `background` so the override can be read from the environment at all.
private struct WindowTopSafeAreaChange: ViewModifier {
    @Environment(\.windowTopSafeAreaInsetOverride) private var override
    let action: (CGFloat) -> Void

    func body(content: Content) -> some View {
        content
            .background {
                // Deliberately NOT sized to zero. The probe reports the *window's* insets, so its own geometry is
                // irrelevant to the value — but its geometry is what schedules the re-read: a 0x0 view gets no
                // `layoutSubviews` when the device rotates, so the last portrait value survived into landscape and
                // drew a cutout tier on a screen with no cutout. A full-size background lays out again on every
                // bounds change, which is exactly the cue needed.
                if override == nil {
                    WindowSafeAreaProbe(onChange: action)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            // A pinned value has no probe to announce it, so it is delivered on appear and whenever it moves.
            .onAppear { override.map(action) }
            .onChange(of: override) { _, new in new.map(action) }
    }
}

private struct WindowSafeAreaProbe: UIViewRepresentable {
    let onChange: (CGFloat) -> Void

    func makeUIView(context _: Context) -> WindowSafeAreaProbeView {
        WindowSafeAreaProbeView(onChange: onChange)
    }

    func updateUIView(_ view: WindowSafeAreaProbeView, context _: Context) {
        view.onChange = onChange
        view.report()
    }
}

/// Zero-size view whose only job is to be in the hierarchy, so `window` resolves. `safeAreaInsetsDidChange` fires on
/// this view for its own insets, which is not what we report — but it is a reliable signal that the window's have
/// moved too, so it doubles as the change notification.
private final class WindowSafeAreaProbeView: UIView {
    var onChange: (CGFloat) -> Void
    /// Last value handed out, so a layout pass that changes nothing doesn't re-enter SwiftUI's update cycle.
    private var reported: CGFloat?

    init(onChange: @escaping (CGFloat) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("WindowSafeAreaProbeView is never loaded from a nib")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        report()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        report()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        report()
    }

    func report() {
        guard let window else { return }
        let top = window.safeAreaInsets.top
        guard reported != top else { return }
        reported = top
        onChange(top)
    }
}
#endif
