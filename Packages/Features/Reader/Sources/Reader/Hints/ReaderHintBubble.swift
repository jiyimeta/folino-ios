import ReaderInteractionCore
import SwiftUI
import UtilityUI
#if os(iOS)
import UIKit
#endif

// Anchored feature-hint bubble, ported from synclick's `FeatureHintBubble`. One hint at a time, anchored to a control,
// with a caret pointing at it. No scrim: an outside tap dismisses the hint AND still activates whatever it hit (a
// window-level `UITapGestureRecognizer` with `cancelsTouchesInView = false`). No ×, and no timeout either: a bubble
// stays until the screen is tapped, because a coach mark that expires on its own can vanish mid-read.
//
// What differs from synclick: anchors arrive as rects through `ReaderHintCoordinator` rather than as SwiftUI
// `Anchor<CGRect>` preferences. Every control hinted here is in the Reader's own view tree (`ReaderTopBarControls`
// draws the strip itself, no `ToolbarItem`s left) and reports its own WINDOW frame directly (`onWindowFrameChange`),
// which is not a detail: SwiftUI's own `.global` is resolved against the hosting view a measurement is taken in, so a
// control planted in a navigation bar's `ToolbarItem` reports its position inside its own item-sized host — a few
// points from the origin, no matter where the bar itself sits.

// MARK: - Anchor plumbing

// PARITY(macos): the anchored feature-hint bubble UI below (window-level tap-through dismiss via
//   `UITapGestureRecognizer`, a `UIViewRepresentable`-hosted overlay) is iOS-only. Ⅳ's Mac reading surface needs its
//   own coach-mark presentation; until then `readerHintAnchor` / `readerHintOverlay` are no-ops on macOS, so the
//   widely shared `ReaderTopBarControls` / `ReaderTransportControl` / `ReaderDisplayInspectorButton` /
//   `ReaderHintWiring` call sites keep compiling unchanged and simply never show a hint.

#if os(iOS)
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
#else
extension View {
    func readerHintAnchor(_ target: ReaderHintTarget, isActive: Bool = true) -> some View {
        self
    }

    func readerHintOverlay(
        coordinator: ReaderHintCoordinator,
        onActivate: @escaping (ReaderFeatureHint) -> Void,
    ) -> some View {
        self
    }
}
#endif

#if os(iOS)
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
                if !active {
                    ReaderHintCoordinator.shared.clearAnchor(for: target)
                }
            }
            .onDisappear { ReaderHintCoordinator.shared.clearAnchor(for: target) }
    }
}

// MARK: - Overlay (positioning + lifecycle)

private struct ReaderHintOverlay: View {
    let coordinator: ReaderHintCoordinator
    let onActivate: (ReaderFeatureHint) -> Void

    /// Where this overlay sits in the window. Measured the same way the anchors are, rather than read off the
    /// `GeometryProxy`, so both ends of the subtraction below are stated in one space by construction — the whole bug
    /// this fixes was two measurements that each looked right and were taken in different spaces.
    @State private var windowOrigin: CGPoint = .zero

    var body: some View {
        GeometryReader { proxy in
            if let hint = coordinator.presentedHint, let anchor = coordinator.anchor(for: hint.target) {
                // The anchor is in window coordinates; this overlay's own window origin converts it into its space.
                // Where the card ends up is `ReaderHintBubbleLayout`'s answer, not this view's — the clamp that keeps
                // the card on screen while the caret keeps tracking the control is the one piece of this bubble that
                // is easy to get subtly wrong, so both platforms ask the same function.
                let rect = anchor.offsetBy(dx: -windowOrigin.x, dy: -windowOrigin.y)
                let frame = ReaderHintBubbleLayout.frame(
                    anchor: ReaderHintRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height),
                    target: hint.target,
                    viewportWidth: proxy.size.width,
                    viewportHeight: proxy.size.height,
                )
                let below = frame.placement == .below

                ZStack {
                    TapThroughObserver { Task { @MainActor in coordinator.dismiss() } }
                        .allowsHitTesting(false)

                    ReaderHintBubble(hint: hint, placement: frame.placement, caretDX: frame.caretDX) {
                        onActivate(hint)
                    }
                    .frame(width: frame.width)
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: below ? .topLeading : .bottomLeading,
                    )
                    .offset(x: frame.originX, y: below ? frame.edgeY : frame.edgeY - proxy.size.height)
                    .transition(
                        .opacity.combined(
                            with: .scale(
                                scale: ReaderHintBubbleLayout.transitionScale,
                                anchor: below ? .top : .bottom,
                            ),
                        ),
                    )
                }
            }
        }
        .onWindowFrameChange { frame in
            windowOrigin = frame.origin
        }
        .animation(
            .easeOut(duration: ReaderHintBubbleLayout.transitionDuration),
            value: coordinator.presentedHint,
        )
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
        return VStack(alignment: .leading, spacing: ReaderHintBubbleLayout.titleMessageSpacing) {
            ReaderHintCopy.title(hint)
                .font(.system(size: ReaderHintBubbleLayout.titleFontSize, weight: .bold))
                .foregroundStyle(Color.accentColor)
            ReaderHintCopy.message(hint)
                .font(.system(size: ReaderHintBubbleLayout.messageFontSize))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, ReaderHintBubbleLayout.horizontalPadding)
        .padding(.vertical, ReaderHintBubbleLayout.verticalPadding)
        // Reserve the caret strip on the protruding side so text never overlaps the arrow.
        .padding(placement == .below ? .top : .bottom, ReaderHintBubbleLayout.caretHeight)
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

/// A rounded-rectangle bubble with a triangular caret on one edge, traced as ONE continuous outline so fill, border and
/// shadow treat card + arrow as a single component. `caretUp` puts the arrow on the top edge (bubble below its
/// anchor); otherwise the bottom edge. `caretDX` shifts the arrow off-center so it keeps pointing at the anchor when
/// the bubble is clamped to a screen edge.
struct ReaderHintBubbleShape: Shape {
    var caretUp: Bool
    var caretDX: CGFloat

    func path(in rect: CGRect) -> Path {
        let radius = ReaderHintBubbleLayout.cornerRadius
        let caretHeight = ReaderHintBubbleLayout.caretHeight
        let halfCaret = ReaderHintBubbleLayout.caretWidth / 2
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
                    placement: hint.target.placement(),
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
#endif
