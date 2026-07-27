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
extension View {
    /// Catches taps on the paper AROUND the engraving — the page margins and, above all, the run-out below the last
    /// system — and deselects.
    ///
    /// It has to be a `background`, sized to the padded frame, rather than another gesture on the score surface:
    /// that surface's frame stops where the engraving does, so taps past the bottom system never reached its gesture
    /// at all and the pad stayed lit with nothing selected. Behind the score it only ever sees what the score itself
    /// didn't take, and a tap gesture doesn't consume the pan the scroll containers need.
    @ViewBuilder
    func editingDeselectCatcher(host: ReaderEditingHost?) -> some View {
        if let host, host.isEditing {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { host.onTapOutsideScore() }
        }
    }
}

struct EditingSelectionOverlay: View {
    let host: ReaderEditingHost
    let score: Score
    let document: LayoutDocument

    var body: some View {
        ZStack(alignment: .topLeading) {
            caretLayer
            selectionAnchorReporter
        }
        .frame(width: document.size.width, height: document.size.height, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Reports where the SELECTED item currently sits on screen, so the editing chrome can float its callout beside
    /// it. Draws nothing: it is a zero-alpha rect parked on the selection whose global frame is what gets published.
    ///
    /// The measurement has to happen here rather than in the chrome because only this view knows the document→screen
    /// transform — the surfaces scale and scroll this whole layer, and `frame(in: .global)` is what folds all of that
    /// into one answer. Note the `.onGeometryChange` goes BEFORE `.position`, which otherwise expands the view to the
    /// container and reports the whole document's frame instead of the item's.
    @ViewBuilder
    private var selectionAnchorReporter: some View {
        if let rect = selectionRect {
            Color.clear
                .frame(width: rect.width, height: rect.height)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                    host.onSelectionAnchorChanged(frame)
                }
                .position(x: rect.midX, y: rect.midY)
                .onDisappear { host.onSelectionAnchorChanged(nil) }
        }
    }

    /// The selected item's column, narrowed to its own staff band — the same geometry the caret uses, since the
    /// engine's cursor frame spans the entire system vertically.
    private var selectionRect: CGRect? {
        guard case let .single(item) = host.selection,
              let frame = document.cursorFrame(for: .item(item), in: score),
              let band = staffBand(for: item.staff, measureIndex: item.measureIndex)
        else { return nil }
        return CGRect(x: frame.minX, y: band.top, width: max(frame.width, 1), height: band.height)
    }

    /// The caret, drawn as the same translucent column the transport's playback head uses
    /// (`playbackCursorColor: .accentColor.opacity(0.6)`, see the zoomed surfaces) — because it means the same thing:
    /// "the music is here". A different shape for the same idea only asks the reader to learn two marks; the bar and
    /// pennant this replaced also read as a text caret sitting BETWEEN two notes, when what it actually marks is the
    /// slot the next note goes INTO.
    @ViewBuilder
    private var caretLayer: some View {
        if let rect = caretRect {
            Rectangle()
                .fill(Color.accentColor.opacity(0.6))
                // Painted OVER the score but multiplied INTO it, so the staff lines and any notehead in the column
                // stay black on top of the tint — the caret reads as highlighted paper rather than a wash over the
                // music. Drawing it behind `ScoreView` instead doesn't work: that view fills itself with opaque white
                // (`ScoreView.swift`, `.background(Color.white)`), so a caret underneath simply vanished.
                .blendMode(.multiply)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .animation(.snappy(duration: 0.15), value: host.caretItem)
        }
    }

    /// The caret's column (from `document.cursorFrame(for:in:)`, `CursorFrame.swift:13` — its Y spans the whole
    /// system) narrowed to `caretItem`'s own staff band: one `sp` above the staff top to one `sp` below the staff
    /// bottom (a staff is 4 sp tall, so the total band is 6 sp). Narrowed, unlike the playback head, because editing
    /// happens in one staff at a time. `nil` when `caretItem` is unset, doesn't resolve to a laid-out frame (e.g. a
    /// stale ID right after an edit reflows the document), or names a staff/measure this document doesn't contain.
    private var caretRect: CGRect? {
        guard let item = host.caretItem,
              let frame = document.cursorFrame(for: .item(item), in: score),
              let band = staffBand(for: item.staff, measureIndex: item.measureIndex)
        else { return nil }
        return CGRect(x: frame.minX, y: band.top, width: max(frame.width, 2), height: band.height)
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
}
