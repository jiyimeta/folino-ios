import SheetMusicCore
import SheetMusicLayout
import SheetMusicUI
import SwiftUI

/// The insertion caret drawn over `ScoreView` while `ReaderEditingHost.isEditing` is true, narrowed to the caret
/// item's own staff band.
///
/// **Nothing here is hit-testable, deliberately.** An earlier version put a full-surface `Color.clear` +
/// `contentShape` layer over the score to host a long-press loupe, a Pencil hover pre-highlight and a pitch-drag
/// handle. That layer covered `ScoreView`, which broke tap-to-select outright (SwiftUI delivers a touch only to the
/// topmost hit-testable view and its ancestors) and, once tapping was routed through it, still swallowed the pan and
/// swipe the scroll containers need — so a score could not be scrolled or paged while editing. Selection now goes
/// through each surface's own `tapSeekGesture` on `ScoreView`, and this overlay only draws. Any future editing
/// affordance that needs touches has to earn its place against that: it must not blanket the score.
///
/// All geometry is in document coordinates: mounted as a `ZStack` sibling of `ScoreView`, which the surface scales as
/// a whole, so no zoom conversion is needed here.
struct EditingSelectionOverlay: View {
    let host: ReaderEditingHost
    let score: Score
    let document: LayoutDocument

    var body: some View {
        caretLayer
            .frame(width: document.size.width, height: document.size.height, alignment: .topLeading)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var caretLayer: some View {
        if let geometry = caretGeometry {
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.accentColor)
                    .frame(width: 2, height: geometry.band.height)
                CaretCap()
                    .fill(Color.accentColor)
                    .frame(width: 8, height: 5)
            }
            .frame(width: 8, height: geometry.band.height, alignment: .top)
            .position(x: geometry.x, y: geometry.band.top + geometry.band.height / 2)
            .animation(.snappy(duration: 0.15), value: host.caretItem)
        }
    }

    /// The caret's X column (from `document.cursorFrame(for:in:)`, `CursorFrame.swift:13` — its Y spans the whole
    /// system) narrowed to `caretItem`'s own staff band: one `sp` above the staff top to one `sp` below the staff
    /// bottom (a staff is 4 sp tall, so the total band is 6 sp). `nil` when `caretItem` is unset, doesn't resolve to
    /// a laid-out frame (e.g. a stale ID right after an edit reflows the document), or names a staff/measure this
    /// document doesn't contain.
    private var caretGeometry: (x: CGFloat, band: (top: CGFloat, height: CGFloat))? {
        guard let item = host.caretItem,
              let frame = document.cursorFrame(for: .item(item), in: score)
        else { return nil }
        guard let band = staffBand(for: item.staff, measureIndex: item.measureIndex) else { return nil }
        let sp = document.metrics.sp
        return (x: frame.minX - sp * 0.8, band: band)
    }

    /// Vertical band (document coords) spanning `staff`'s five lines, one `sp` clear on each side, within the
    /// `LayoutSystem` that contains `measureIndex`. `nil` when the staff/measure can't be located.
    private func staffBand(for staff: StaffAddress, measureIndex: Int) -> (top: CGFloat, height: CGFloat)? {
        guard let system = document.systems.first(where: { candidate in
            candidate.measures.contains { $0.measureIndex == measureIndex }
        }), let flatIndex = system.flatIndex(for: staff) else { return nil }
        let sp = document.metrics.sp
        let staffTop = system.origin.y + system.staffOrigins[flatIndex].y
        return (top: staffTop - sp, height: 6 * sp)
    }

    /// Small downward-pointing triangle drawn at the caret's top, like a flag marking the insertion column.
    private struct CaretCap: Shape {
        func path(in rect: CGRect) -> Path {
            Path { path in
                path.move(to: CGPoint(x: rect.minX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
                path.closeSubpath()
            }
        }
    }
}
