import SwiftUI

/// Floats `EditorCalloutView` beside the selected note or rest, clamped to stay on screen and clear of the pad.
///
/// Its own `View`, and NOT part of `EditorChromeView.body`, on purpose: `selectionAnchor` is republished on every
/// scroll and zoom frame while a note is selected, so whichever body reads it re-runs at that rate. Kept here, that
/// is one small capsule; read from the chrome's body it would drag the pad, the header and their menus along with
/// it — the same over-invalidation that made the Reader's playback cursor reset open menus.
struct SelectionCalloutLayer: View {
    let viewModel: EditorViewModel
    /// Room at the bottom the callout must not descend into — the pad plus the transport underneath it.
    let bottomClearance: CGFloat

    /// Measured, not assumed: the capsule's size decides how far from the note it has to sit and how close to the
    /// screen edges it may go.
    @State private var calloutSize: CGSize = .zero

    /// Which side of the note the card parks on. Persisted like the pad's placement: someone who moves it off the
    /// music once means it for the next note too.
    @AppStorage("editorCalloutPlacement") private var storedSide = CalloutSide.above.rawValue
    @State private var side: CalloutSide = .above
    /// Live finger travel. `@GestureState` so a cancelled drag can't strand the card between the two sides.
    @GestureState private var dragTranslation: CGFloat = 0
    /// Held for one frame after the finger lifts so the card glides from where it was released instead of blinking
    /// back to its old side first — the same two-part release the pad uses.
    @State private var releasedTranslation: CGFloat = 0

    /// Gap between the note and the card.
    private static let noteGap: CGFloat = 12
    private static let edgeInset: CGFloat = 8

    var body: some View {
        GeometryReader { proxy in
            if viewModel.hasSelectionCallout, let anchor = viewModel.selectionAnchor {
                let sides = availableSides(for: anchor, in: proxy)
                EditorCalloutView(viewModel: viewModel)
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { calloutSize = $0 }
                    .offset(y: dragTranslation + releasedTranslation)
                    .position(position(for: anchor, in: proxy, side: resolved(side, among: sides)))
                    // Same trick as the pad: a high-priority drag that only wins once the finger actually travels, so
                    // a tap still reaches the key underneath and a drag cancels it rather than firing it on release.
                    .highPriorityGesture(dragGesture(anchor: anchor, proxy: proxy, sides: sides))
                    .animation(.snappy(duration: 0.18), value: viewModel.selectedItem)
            }
        }
        .onAppear { side = CalloutSide(rawValue: storedSide) ?? .above }
    }

    /// Which sides the card may park on for this note. The card must clear the header at the top and the pad plus
    /// transport at the bottom, so near either end of the screen only the far side is offered — dragging it into the
    /// chrome would hide it behind the very controls it complements.
    private func availableSides(for anchor: CGRect, in proxy: GeometryProxy) -> [CalloutSide] {
        let top = proxy.safeAreaInsets.top + calloutSize.height / 2 + Self.edgeInset
        let bottom = proxy.size.height - bottomClearance - calloutSize.height / 2
        let sides = CalloutSide.allCases.filter { candidate in
            let y = unclampedY(for: anchor, in: proxy, side: candidate)
            return y >= top && y <= bottom
        }
        // Neither fits (a tall card on a short viewport): keep both and let the clamp in `position` decide.
        return sides.isEmpty ? CalloutSide.allCases : sides
    }

    private func resolved(_ preferred: CalloutSide, among sides: [CalloutSide]) -> CalloutSide {
        sides.contains(preferred) ? preferred : (sides.first ?? preferred)
    }

    /// Where the card's center wants to be for `side`, before any clamping — the value the snap decision compares.
    private func unclampedY(for anchor: CGRect, in proxy: GeometryProxy, side: CalloutSide) -> CGFloat {
        let global = proxy.frame(in: .global)
        let half = calloutSize.height / 2
        return switch side {
        case .above: anchor.minY - global.minY - half - Self.noteGap
        case .below: anchor.maxY - global.minY + half + Self.noteGap
        }
    }

    /// The card's center: on `side` of the note, then clamped into the viewport. The anchor arrives in GLOBAL
    /// coordinates (only the Reader's overlay knows the document→screen transform), so it is converted through this
    /// layer's own global frame first.
    private func position(for anchor: CGRect, in proxy: GeometryProxy, side: CalloutSide) -> CGPoint {
        let global = proxy.frame(in: .global)
        let localAnchor = anchor.offsetBy(dx: -global.minX, dy: -global.minY)
        let rawX = localAnchor.midX
        let rawY = unclampedY(for: anchor, in: proxy, side: side)

        // Clamping keeps the card reachable while the note it belongs to is on screen. Once the note has scrolled
        // out, clamping would strand the card at the edge pointing at nothing — so it goes with the note instead and
        // leaves the screen too. Judged per axis, since a note can leave sideways in horizontal mode.
        let viewport = CGRect(origin: .zero, size: proxy.size)
        let halfWidth = calloutSize.width / 2
        let minX = halfWidth + Self.edgeInset
        let maxX = max(minX, proxy.size.width - halfWidth - Self.edgeInset)
        let x = localAnchor.maxX >= 0 && localAnchor.minX <= viewport.maxX ? min(max(rawX, minX), maxX) : rawX

        let topLimit = proxy.safeAreaInsets.top + calloutSize.height / 2 + Self.edgeInset
        let bottomLimit = max(topLimit, proxy.size.height - bottomClearance - calloutSize.height / 2)
        let y = localAnchor.maxY >= 0 && localAnchor.minY <= viewport.maxY
            ? min(max(rawY, topLimit), bottomLimit)
            : rawY
        return CGPoint(x: x, y: y)
    }

    private func dragGesture(anchor: CGRect, proxy: GeometryProxy, sides: [CalloutSide]) -> some Gesture {
        // GLOBAL space, like the pad's: in `.local` the translation is measured against a frame this very gesture is
        // moving, which feeds back and judders.
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .updating($dragTranslation) { value, state, _ in state = value.translation.height }
            .onEnded { value in
                releasedTranslation = value.translation.height
                let current = resolved(side, among: sides)
                let released = unclampedY(for: anchor, in: proxy, side: current) + value.predictedEndTranslation.height
                // Snap to whichever ALLOWED side the card was thrown nearest — with only one allowed, that's the one.
                let destination = sides.min(by: { first, second in
                    abs(unclampedY(for: anchor, in: proxy, side: first) - released)
                        < abs(unclampedY(for: anchor, in: proxy, side: second) - released)
                }) ?? current
                withAnimation(.snappy(duration: 0.28)) {
                    side = destination
                    releasedTranslation = 0
                }
                storedSide = destination.rawValue
            }
    }
}

/// Which side of the selected note the callout parks on. Unlike the pad — which travels between the top and bottom of
/// the SCREEN — this one travels around the note it belongs to, so it stays attached to what it edits.
private enum CalloutSide: String, CaseIterable {
    case above
    case below
}
