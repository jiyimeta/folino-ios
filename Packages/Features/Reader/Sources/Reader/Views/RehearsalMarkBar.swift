import SheetMusicCore
import SwiftUI
import UtilityUI

/// A row of rehearsal-mark "speech bubbles" laid out above the seek bar by each mark's time fraction. Tapping a bubble
/// seeks to that mark; dragging across the bar discretely seeks to whichever mark is nearest the finger, snapping from
/// mark to mark as it moves. Sized to match the seek bar's width (both live inside the card's content padding), so a
/// bubble at fraction `f` lines up with the seek bar's position `f`.
///
/// Two behaviors keep dense / edge-of-bar marks usable:
/// - **Stacking order:** the mark governing the current position (the last one at or before `currentFraction`) is drawn
///   frontmost; among the rest, earlier marks sit in front of later ones.
/// - **Edge handling:** a bubble whose body would spill past the bar edge slides its body inward while its tail stays
///   pointed at the true position.
struct RehearsalMarkBar: View {
    let marks: [ReaderRehearsalMark]
    /// Current playback (or scrub) position as a 0...1 fraction, used to pick the frontmost mark.
    let currentFraction: Double
    let onSeek: (ScoreCursor) -> Void

    /// Tracks the bubble's own height (10pt label + its vertical padding + the tail), so the bar takes no more room
    /// than the bubbles need — the transport card's expanded height is measured, and slack here inflates it.
    static let height: CGFloat = 28

    /// Measured body width per mark id, used to clamp the body within the bar.
    @State private var bodyWidths: [String: CGFloat] = [:]

    /// Id of the mark last seeked to during an in-progress drag, so a continuous drag only re-seeks when it crosses
    /// into a new mark's neighborhood (discrete, mark-to-mark snapping) rather than firing on every touch update.
    @State private var draggedMarkID: String?

    private var currentMarkID: String? {
        marks.last { $0.fraction <= currentFraction }?.id
    }

    var body: some View {
        GeometryReader { geometry in
            let barWidth = geometry.size.width
            // Resolve the current mark once per layout pass — `currentMarkID` is O(N), so reading it per row would be
            // O(N^2). Hoisting it keeps the comparison and stacking order linear.
            let currentID = currentMarkID
            ZStack {
                // Transparent full-bar hit layer so a drag registers anywhere across the bar — including the gaps
                // between bubbles. It sits behind the bubbles, so taps still land on the bubble buttons in front.
                Color.clear.contentShape(Rectangle())

                ForEach(Array(marks.enumerated()), id: \.element.id) { index, mark in
                    let trueX = barWidth * mark.fraction
                    let width = bodyWidths[mark.id] ?? 0
                    let half = width / 2
                    // Keep the body fully on the bar; the tail still points at `trueX` via its offset.
                    let center = width > 0 ? min(max(trueX, half), max(half, barWidth - half)) : trueX
                    let rawTailOffset = trueX - center
                    // Keep the tail under the rounded body, not sliding off its end.
                    let maxTailOffset = max(0, half - 12)
                    let tailOffset = min(max(rawTailOffset, -maxTailOffset), maxTailOffset)

                    RehearsalMarkButton(
                        text: mark.text,
                        isCurrent: mark.id == currentID,
                        tailOffset: tailOffset,
                        action: { onSeek(mark.cursor) },
                        onBodyWidthChange: { bodyWidths[mark.id] = $0 },
                    )
                    .position(x: center, y: Self.height / 2)
                    .zIndex(stackOrder(for: mark, index: index, currentID: currentID))
                }
            }
            // Drag-to-select: maps the finger's x to the nearest mark and seeks to it, snapping discretely between
            // marks. `minimumDistance` keeps short presses falling through to the bubble buttons (precise taps), while
            // anything past the threshold becomes a drag. Re-seeks live (not just on release) as the nearest mark
            // changes — `simultaneousGesture`, not `gesture`, so the drag is recognized alongside the bubble buttons
            // instead of waiting for a button's press to resolve at touch-up (else every seek defers to drag end).
            .simultaneousGesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        let fraction = min(max(value.location.x / barWidth, 0), 1)
                        guard let mark = nearestMark(toFraction: fraction) else { return }
                        if mark.id != draggedMarkID {
                            draggedMarkID = mark.id
                            onSeek(mark.cursor)
                        }
                    }
                    .onEnded { _ in draggedMarkID = nil },
            )
        }
        .frame(height: Self.height)
    }

    /// The mark whose time fraction lies closest to `fraction` (the drag's normalized x), used to snap a drag to it.
    private func nearestMark(toFraction fraction: Double) -> ReaderRehearsalMark? {
        marks.min { abs($0.fraction - fraction) < abs($1.fraction - fraction) }
    }

    /// Frontmost = the mark governing the current position; otherwise later marks sit in front of earlier ones.
    private func stackOrder(for mark: ReaderRehearsalMark, index: Int, currentID: String?) -> Double {
        if mark.id == currentID {
            return Double(marks.count + 1)
        }
        return Double(index + 1)
    }
}

/// A single rehearsal-mark bubble: a rounded label with a downward tail pointing at its position on the seek bar. The
/// text is clipped to a sensible max width with a tail ellipsis. The whole bubble is an interactive (and opaque) glass
/// button so it reads clearly over the score.
private struct RehearsalMarkButton: View {
    let text: String
    /// The mark governing the current position — emphasized (accent fill) and drawn frontmost.
    let isCurrent: Bool
    /// Horizontal offset of the tail tip from the body center, used when the body has been slid inward at an edge.
    let tailOffset: CGFloat
    let action: () -> Void
    let onBodyWidthChange: (CGFloat) -> Void

    private static let maxTextWidth: CGFloat = 90
    private static let tailHeight: CGFloat = 9

    var body: some View {
        let shape = SpeechBubble(tailHeight: Self.tailHeight, tailOffset: tailOffset)
        Button(action: action) {
            Text(text)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(isCurrent ? Color.white : Color.primary)
                .frame(maxWidth: Self.maxTextWidth)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .padding(.bottom, Self.tailHeight)
        }
        .buttonStyle(.plain)
        // Solid, shadowless fills (materials still render a faint elevation shadow and read low-contrast over glass).
        // The current section is accent-filled to stand out; the rest are an opaque chip with a hairline border.
        .background(isCurrent ? Color.accentColor : Color.systemBackgroundCompat, in: shape)
        .overlay(shape.stroke(isCurrent ? Color.clear : Color.primary.opacity(0.18), lineWidth: 0.5))
        // Hug the text: `.position` in the bar proposes the full width, which would otherwise stretch the `maxWidth`
        // frame to its cap on every bubble. `fixedSize` pins the bubble to its ideal width, so `maxWidth` only kicks in
        // (clamping + truncating) once the text is actually wider than the cap.
        .fixedSize()
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }, action: onBodyWidthChange)
    }
}

/// Rounded-rectangle bubble body with a small triangular tail on the bottom edge. `tailOffset` shifts the tail tip
/// horizontally from the body center (0 = centered) so the body can slide inward at the bar edges while the tail keeps
/// pointing at the mark's true position.
private struct SpeechBubble: Shape {
    var cornerRadius: CGFloat = 8
    var tailWidth: CGFloat = 10
    var tailHeight: CGFloat = 5
    var tailOffset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let bottom = rect.maxY - tailHeight
        let radius = min(cornerRadius, (rect.width / 2) - 1, (bottom - rect.minY) / 2)
        let tipX = rect.midX + tailOffset

        // One continuous outline (rounded rectangle that detours into the tail along its bottom edge), so a stroke has
        // no seam where the tail meets the body.
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + radius, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addArc(
            tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
            tangent2End: CGPoint(x: rect.maxX, y: rect.minY + radius),
            radius: radius,
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: bottom - radius))
        path.addArc(
            tangent1End: CGPoint(x: rect.maxX, y: bottom),
            tangent2End: CGPoint(x: rect.maxX - radius, y: bottom),
            radius: radius,
        )
        path.addLine(to: CGPoint(x: tipX + tailWidth / 2, y: bottom))
        path.addLine(to: CGPoint(x: tipX, y: rect.maxY))
        path.addLine(to: CGPoint(x: tipX - tailWidth / 2, y: bottom))
        path.addLine(to: CGPoint(x: rect.minX + radius, y: bottom))
        path.addArc(
            tangent1End: CGPoint(x: rect.minX, y: bottom),
            tangent2End: CGPoint(x: rect.minX, y: bottom - radius),
            radius: radius,
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addArc(
            tangent1End: CGPoint(x: rect.minX, y: rect.minY),
            tangent2End: CGPoint(x: rect.minX + radius, y: rect.minY),
            radius: radius,
        )
        path.closeSubpath()
        return path
    }
}

#if DEBUG
#Preview("Rehearsal mark bubbles") {
    let marks = [
        ReaderRehearsalMark(id: "0", text: "A", fraction: 0.0, cursor: .beat(measureIndex: 0, tickInMeasure: 0)),
        ReaderRehearsalMark(id: "1", text: "B", fraction: 0.45, cursor: .beat(measureIndex: 4, tickInMeasure: 0)),
        ReaderRehearsalMark(
            id: "2",
            text: "Chorus — second time, softer",
            fraction: 1.0,
            cursor: .beat(measureIndex: 8, tickInMeasure: 0),
        ),
    ]
    return RehearsalMarkBar(marks: marks, currentFraction: 0.5, onSeek: { _ in })
        .border(.orange)
        .padding(40)
}
#endif
