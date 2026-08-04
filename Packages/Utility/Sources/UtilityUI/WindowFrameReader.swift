import SwiftUI
import UIKit

extension View {
    /// Reports this view's frame in the host WINDOW's coordinate space, whenever it changes.
    ///
    /// Reach for this instead of `onGeometryChange(for: CGRect.self) { $0.frame(in: .global) }` whenever the
    /// measurement has to be compared against one taken in a DIFFERENT view tree. SwiftUI resolves `.global` against
    /// the root of the hosting view the measured view lives in — and a navigation bar hosts its `ToolbarItem`s in a
    /// hosting context of their own, so a bar button reports a frame near the origin of its own item-sized host rather
    /// than where it sits on screen. UIKit's window is the one space every tree in the scene actually shares.
    ///
    /// The probe re-measures on every cue that can move a view without resizing it — a bar item shifting sideways when
    /// a neighbour folds into the overflow menu is exactly that, and `layoutSubviews` alone would sleep through it.
    /// Identical repeat frames are swallowed, and the callback always lands outside the layout pass that triggered it,
    /// so it is safe to write SwiftUI state from.
    ///
    /// Nothing is reported while the view has no window (it is not on screen, so it has no position to speak of).
    public func onWindowFrameChange(_ action: @escaping @MainActor (CGRect) -> Void) -> some View {
        modifier(WindowFrameChangeModifier(action: action))
    }
}

private struct WindowFrameChangeModifier: ViewModifier {
    let action: @MainActor (CGRect) -> Void

    /// Bumped from SwiftUI's own geometry callback. The value that callback reports is the unusable one described
    /// above; the fact that it fired is not, and for a view that moves inside its own tree it is the earliest cue
    /// there is.
    @State private var geometryRevision = 0

    func body(content: Content) -> some View {
        content
            .background { WindowFrameProbe(revision: geometryRevision, onChange: action) }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { _ in
                geometryRevision &+= 1
            }
    }
}

private struct WindowFrameProbe: UIViewRepresentable {
    /// Never read. Its only job is to make SwiftUI call `updateUIView` when the geometry cue fires.
    let revision: Int
    let onChange: @MainActor (CGRect) -> Void

    func makeUIView(context _: Context) -> WindowFrameProbeView {
        let view = WindowFrameProbeView()
        view.isUserInteractionEnabled = false
        view.onChange = onChange
        return view
    }

    func updateUIView(_ uiView: WindowFrameProbeView, context _: Context) {
        uiView.onChange = onChange
        uiView.scheduleReport()
    }

    /// Takes exactly the size it is offered, so the probe's frame IS the measured view's frame. A bare `UIView` has no
    /// intrinsic content size, and the default sizing would collapse the background to nothing.
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView _: WindowFrameProbeView,
        context _: Context,
    ) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}

private final class WindowFrameProbeView: UIView {
    var onChange: (@MainActor (CGRect) -> Void)?

    private var reported: CGRect?
    private var isReportScheduled = false

    override func layoutSubviews() {
        super.layoutSubviews()
        scheduleReport()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // A different window (or none) means the frame we last reported describes nothing — re-report even if the
        // numbers happen to come out the same.
        reported = nil
        scheduleReport()
    }

    /// Reports on the next main-actor turn rather than inline: every cue that gets here fires from inside a layout
    /// pass, and what this feeds is SwiftUI state.
    func scheduleReport() {
        guard !isReportScheduled else { return }
        isReportScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            isReportScheduled = false
            report()
        }
    }

    private func report() {
        guard let window else { return }
        let frame = convert(bounds, to: window)
        guard frame != reported else { return }
        reported = frame
        onChange?(frame)
    }
}
