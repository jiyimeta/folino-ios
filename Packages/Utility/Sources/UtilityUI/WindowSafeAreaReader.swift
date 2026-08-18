import SwiftUI
import UIKit

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
    /// leftovers.
    public func onWindowTopSafeAreaChange(_ action: @escaping (CGFloat) -> Void) -> some View {
        // Deliberately NOT sized to zero. The probe reports the *window's* insets, so its own geometry is irrelevant
        // to the value — but its geometry is what schedules the re-read: a 0x0 view gets no `layoutSubviews` when the
        // device rotates, so the last portrait value survived into landscape and drew a cutout tier on a screen with
        // no cutout. A full-size background lays out again on every bounds change, which is exactly the cue needed.
        background(
            WindowSafeAreaProbe(onChange: action)
                .allowsHitTesting(false)
                .accessibilityHidden(true),
        )
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
