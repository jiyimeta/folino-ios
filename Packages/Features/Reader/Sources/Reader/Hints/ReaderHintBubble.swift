import SwiftUI
import UIKit
import UtilityUI

// Anchored feature-hint bubble, ported from synclick's `FeatureHintBubble`. One hint at a time, anchored to a control,
// with a caret pointing at it. No scrim: an outside tap dismisses the hint AND still activates whatever it hit (a
// window-level `UITapGestureRecognizer` with `cancelsTouchesInView = false`). No × — the bubble times itself out.
//
// What differs from synclick: anchors arrive as rects through `ReaderHintCoordinator` rather than as SwiftUI
// `Anchor<CGRect>` preferences, because half the controls hinted here are `ToolbarItem`s hosted by the navigation bar,
// and preferences do not cross that hosting boundary. Those rects are in WINDOW coordinates (`onWindowFrameChange`),
// which is not a detail: SwiftUI's own `.global` is resolved against the hosting view a measurement is taken in, so a
// bar button measured that way reports its position inside its own item-sized host — a few points from the origin,
// which is precisely where every toolbar-anchored bubble used to land. The window is the only space the bar's hosting
// context and the Reader's own tree agree on.

// MARK: - Anchor plumbing

extension View {
    /// Reports this view's window frame as the anchor for `target`, so a hint pointing at it knows where to put its
    /// caret. Safe to attach unconditionally: nothing is drawn, and writes are change-guarded inside the coordinator.
    ///
    /// `isActive: false` withdraws the anchor instead — which also withdraws the hint, since a hint is only ever
    /// offered for a control that has reported itself. That is how a hint whose copy only holds in one state (the
    /// transport's "swipe right to shrink it") stays out of the rotation in the other.
    func readerHintAnchor(_ target: ReaderHintTarget, isActive: Bool = true) -> some View {
        modifier(ReaderHintAnchorModifier(target: target, isActive: isActive))
    }

    /// Declares that a NAVIGATION-BAR control is currently on screen, so the hint pointing at it can be matched to one
    /// of the bar's measured items.
    ///
    /// Bar items get this instead of `readerHintAnchor` for a measured reason: nothing hosted by the bar can report
    /// where it is (see `ReaderBarItemLocator`). Attaching it is a statement of presence, not of position — which is
    /// all the Reader is in a position to know, and all the matching needs.
    func readerHintBarAnchor(_ target: ReaderHintTarget) -> some View {
        modifier(ReaderHintBarAnchorModifier(target: target))
    }

    /// Installs the hint overlay. Attach to the Reader's root, above the score and the transport. `onActivate` runs
    /// when the bubble body itself is tapped — a coach mark is a button for the thing it describes, so tapping it does
    /// that thing rather than merely getting out of the way.
    func readerHintOverlay(
        coordinator: ReaderHintCoordinator,
        onActivate: @escaping (ReaderFeatureHint) -> Void,
    ) -> some View {
        overlay { ReaderHintOverlay(coordinator: coordinator, onActivate: onActivate) }
    }
}

private struct ReaderHintAnchorModifier: ViewModifier {
    let target: ReaderHintTarget
    let isActive: Bool

    func body(content: Content) -> some View {
        content
            .onWindowFrameChange { rect in
                guard isActive else { return }
                ReaderHintCoordinator.shared.setAnchor(rect, for: target)
            }
            .onChange(of: isActive, initial: true) { _, active in
                if !active { ReaderHintCoordinator.shared.clearAnchor(for: target) }
            }
            .onDisappear { ReaderHintCoordinator.shared.clearAnchor(for: target) }
    }
}

private struct ReaderHintBarAnchorModifier: ViewModifier {
    let target: ReaderHintTarget

    func body(content: Content) -> some View {
        content
            .onAppear { ReaderHintCoordinator.shared.registerBarTarget(target, slot: target.barSlot) }
            .onDisappear { ReaderHintCoordinator.shared.registerBarTarget(target, slot: nil) }
    }
}

// MARK: - Overlay (positioning + lifecycle)

private struct ReaderHintOverlay: View {
    let coordinator: ReaderHintCoordinator
    let onActivate: (ReaderFeatureHint) -> Void

    private let caretGap: CGFloat = 4 // gap between the caret apex and the control
    private let edgeMargin: CGFloat = 14 // min margin from the screen edge
    private let maxBubbleWidth: CGFloat = 280
    private let caretInset: CGFloat = 24 // keep the caret ≥ cornerRadius + halfCaret from the corners

    /// Where this overlay sits in the window. Measured the same way the anchors are, rather than read off the
    /// `GeometryProxy`, so both ends of the subtraction below are stated in one space by construction — the whole bug
    /// this fixes was two measurements that each looked right and were taken in different spaces.
    @State private var windowOrigin: CGPoint = .zero

    var body: some View {
        GeometryReader { proxy in
            if let hint = coordinator.presentedHint, let anchor = coordinator.anchor(for: hint.target) {
                // The anchor is in window coordinates; this overlay's own window origin converts it into its space.
                let rect = anchor.offsetBy(dx: -windowOrigin.x, dy: -windowOrigin.y)
                let width = min(maxBubbleWidth, proxy.size.width - 2 * edgeMargin)
                let minCenterX = edgeMargin + width / 2
                let maxCenterX = proxy.size.width - edgeMargin - width / 2
                let centerX = min(max(rect.midX, minCenterX), max(minCenterX, maxCenterX))
                // The caret keeps tracking the control even when the bubble itself is clamped to a screen edge.
                let caretDX = min(max(rect.midX - centerX, -width / 2 + caretInset), width / 2 - caretInset)
                let placement = hint.target.placement
                let below = placement == .below
                // Pin the bubble's caret-side edge a fixed gap from the control — height-independent, so a long
                // multi-line message grows away from the anchor instead of riding over it.
                let edgeY = below ? rect.maxY + caretGap : rect.minY - caretGap

                ZStack {
                    TapThroughObserver { Task { @MainActor in coordinator.dismiss() } }
                        .allowsHitTesting(false)

                    ReaderHintBubble(hint: hint, placement: placement, caretDX: caretDX) {
                        onActivate(hint)
                    }
                    .frame(width: width)
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: below ? .topLeading : .bottomLeading,
                    )
                    .offset(x: centerX - width / 2, y: below ? edgeY : edgeY - proxy.size.height)
                    .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: below ? .top : .bottom)))
                }
            }
        }
        // Doubles as the Reader's own position report: on iPad two navigation bars can be on screen at once, and this
        // is what tells the bar locator which of them belongs to the Reader asking.
        .onWindowFrameChange { frame in
            windowOrigin = frame.origin
            coordinator.setReaderRegion(frame)
        }
        .animation(.easeOut(duration: 0.2), value: coordinator.presentedHint)
    }
}

// MARK: - Bubble

struct ReaderHintBubble: View {
    let hint: ReaderFeatureHint
    let placement: ReaderHintPlacement
    let caretDX: CGFloat
    let onActivate: () -> Void

    var body: some View {
        let shape = ReaderHintBubbleShape(caretUp: placement == .below, caretDX: caretDX)
        return VStack(alignment: .leading, spacing: 3) {
            ReaderHintCopy.title(hint)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color.accentColor)
            ReaderHintCopy.message(hint)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        // Reserve the caret strip on the protruding side so text never overlaps the arrow.
        .padding(placement == .below ? .top : .bottom, ReaderHintCaretMetrics.height)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Card and arrow are ONE shape, so a single shadow wraps the whole silhouette — no internal seam where the
        // arrow meets the body.
        .background(
            shape
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
                .overlay(shape.stroke(Color.primary.opacity(0.10), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.20), radius: 12, y: 4),
        )
        .contentShape(shape)
        .onTapGesture(perform: onActivate)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// Caret geometry, shared by `ReaderHintBubbleShape` and the overlay's placement math.
enum ReaderHintCaretMetrics {
    static let width: CGFloat = 18
    static let height: CGFloat = 8
    static let cornerRadius: CGFloat = 14
}

/// A rounded-rectangle bubble with a triangular caret on one edge, traced as ONE continuous outline so fill, border and
/// shadow treat card + arrow as a single component. `caretUp` puts the arrow on the top edge (bubble below its
/// anchor); otherwise the bottom edge. `caretDX` shifts the arrow off-center so it keeps pointing at the anchor when
/// the bubble is clamped to a screen edge.
struct ReaderHintBubbleShape: Shape {
    var caretUp: Bool
    var caretDX: CGFloat

    func path(in rect: CGRect) -> Path {
        let radius = ReaderHintCaretMetrics.cornerRadius
        let caretHeight = ReaderHintCaretMetrics.height
        let halfCaret = ReaderHintCaretMetrics.width / 2
        let apexX = rect.midX + caretDX
        var path = Path()

        if caretUp {
            let top = rect.minY + caretHeight
            path.move(to: CGPoint(x: apexX - halfCaret, y: top))
            path.addLine(to: CGPoint(x: apexX, y: rect.minY)) // up to the apex
            path.addLine(to: CGPoint(x: apexX + halfCaret, y: top)) // back down to the body edge
            path.addArc(
                tangent1End: CGPoint(x: rect.maxX, y: top),
                tangent2End: CGPoint(x: rect.maxX, y: rect.maxY), radius: radius,
            )
            path.addArc(
                tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
                tangent2End: CGPoint(x: rect.minX, y: rect.maxY), radius: radius,
            )
            path.addArc(
                tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
                tangent2End: CGPoint(x: rect.minX, y: top), radius: radius,
            )
            path.addArc(
                tangent1End: CGPoint(x: rect.minX, y: top),
                tangent2End: CGPoint(x: apexX - halfCaret, y: top), radius: radius,
            )
        } else {
            let bottom = rect.maxY - caretHeight
            path.move(to: CGPoint(x: apexX + halfCaret, y: bottom))
            path.addLine(to: CGPoint(x: apexX, y: rect.maxY)) // down to the apex
            path.addLine(to: CGPoint(x: apexX - halfCaret, y: bottom)) // back up to the body edge
            path.addArc(
                tangent1End: CGPoint(x: rect.minX, y: bottom),
                tangent2End: CGPoint(x: rect.minX, y: rect.minY), radius: radius,
            )
            path.addArc(
                tangent1End: CGPoint(x: rect.minX, y: rect.minY),
                tangent2End: CGPoint(x: rect.maxX, y: rect.minY), radius: radius,
            )
            path.addArc(
                tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
                tangent2End: CGPoint(x: rect.maxX, y: bottom), radius: radius,
            )
            path.addArc(
                tangent1End: CGPoint(x: rect.maxX, y: bottom),
                tangent2End: CGPoint(x: apexX + halfCaret, y: bottom), radius: radius,
            )
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - Outside-tap observer

/// Installs a `UITapGestureRecognizer` on the host window that reports taps without consuming them
/// (`cancelsTouchesInView = false`), so a tap that dismisses the hint still reaches the control it landed on. The
/// backing view is inert (never blocks) — it exists only to find the window.
private struct TapThroughObserver: UIViewRepresentable {
    let onTap: () -> Void

    func makeUIView(context _: Context) -> WindowTapView {
        let view = WindowTapView()
        view.isUserInteractionEnabled = false
        view.onTap = onTap
        return view
    }

    func updateUIView(_ uiView: WindowTapView, context _: Context) {
        uiView.onTap = onTap
    }

    static func dismantleUIView(_ uiView: WindowTapView, coordinator _: ()) {
        uiView.detachRecognizer()
    }
}

private final class WindowTapView: UIView, UIGestureRecognizerDelegate {
    var onTap: (() -> Void)?

    private var recognizer: UITapGestureRecognizer?
    private weak var recognizerWindow: UIWindow?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        detachRecognizer()
        guard let window else { return }
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        recognizer.delegate = self
        window.addGestureRecognizer(recognizer)
        self.recognizer = recognizer
        recognizerWindow = window
    }

    func detachRecognizer() {
        if let recognizer, let recognizerWindow {
            recognizerWindow.removeGestureRecognizer(recognizer)
        }
        recognizer = nil
        recognizerWindow = nil
    }

    @objc private func handleTap() {
        onTap?()
    }

    func gestureRecognizer(
        _: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer,
    ) -> Bool {
        true
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Hint bubbles") {
    ScrollView {
        VStack(spacing: 28) {
            ForEach(ReaderFeatureHint.allCases, id: \.self) { hint in
                ReaderHintBubble(
                    hint: hint,
                    placement: hint.target.placement,
                    caretDX: 0,
                    onActivate: {},
                )
                .frame(width: 280)
            }
        }
        .padding(24)
    }
    .background(Color(uiColor: .systemGroupedBackground))
}
#endif
