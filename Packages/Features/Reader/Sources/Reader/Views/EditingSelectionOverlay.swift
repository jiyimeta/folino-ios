import SheetMusicCore
import SheetMusicLayout
import SheetMusicUI
import SwiftUI

/// Note-editing chrome drawn on top of `ScoreView` while `ReaderEditingHost.isEditing` is true: a faint tint disc
/// over every rest (advertising "tap to input here"), the insertion caret narrowed to the caret item's own staff
/// band, a publisher that reports the caret's on-screen frame back to the host (feeds the iPhone callout), and —
/// when a single note is selected — an invisible drag handle over its notehead for pitch-drag editing plus a ghost
/// notehead that tracks the drag.
///
/// All geometry here is in document coordinates: this view is mounted as a `ZStack` sibling of `ScoreView` inside
/// `VerticalZoomedSurface.scoreSurface`, which applies the zoom/pinch scaling to the whole stack — so no zoom
/// conversion is needed here. `restAnchors` / `noteheadAnchor` walk `document.systems → measure.elements` and match
/// the `.chord` / `.rest` case shapes exactly the way `ScoreHitTester.hitNote` / `hitRest`
/// (`ScoreHitTester.swift:193-234`) and the Task 8 `LayoutTestSupport.anchorPoint(of:in:)` test helper do —
/// including the notehead's `mirrorDx(stem:sp:)` offset — so a rendered anchor always matches what a tap would hit.
struct EditingSelectionOverlay: View {
    let host: ReaderEditingHost
    let score: Score
    let document: LayoutDocument

    @State private var dragSteps: Int?

    /// Every rest in `document`, resolved once at init — `document` is immutable per view value, and re-walking the
    /// whole score on every render (each frame of a drag, etc.) would be wasteful.
    private let restAnchors: [(id: RestID, point: CGPoint, sp: CGFloat)]

    init(host: ReaderEditingHost, score: Score, document: LayoutDocument) {
        self.host = host
        self.score = score
        self.document = document
        restAnchors = Self.restAnchors(in: document)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            restTintLayer
            caretLayer
            dragLayer
        }
        .frame(width: document.size.width, height: document.size.height, alignment: .topLeading)
        // Belt-and-suspenders: the caret view itself clears `selectionScreenFrame` on every geometry change while
        // it's on screen, but a caret that stops resolving to a frame (item removed by an edit, stale ID after
        // reflow) would otherwise leave the last-published frame stuck. Catch that here too.
        .onChange(of: host.caretItem) { _, newValue in
            if newValue == nil { host.selectionScreenFrame = nil }
        }
    }

    // MARK: - 1. Rest tint

    private var restTintLayer: some View {
        ForEach(restAnchors, id: \.id) { anchor in
            Circle()
                .fill(Color.accentColor.opacity(0.12))
                .frame(width: anchor.sp * 3.6, height: anchor.sp * 3.6)
                .position(anchor.point)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Walks `document.systems → measure.elements` matching `.rest` exactly as `ScoreHitTester.hitRest` does
    /// (`ScoreHitTester.swift:216-234`), so every tint disc sits exactly where a tap would register a rest hit.
    private static func restAnchors(in document: LayoutDocument) -> [(id: RestID, point: CGPoint, sp: CGFloat)] {
        let sp = document.metrics.sp
        var anchors: [(id: RestID, point: CGPoint, sp: CGFloat)] = []
        for system in document.systems {
            for measure in system.measures {
                let base = CGPoint(x: system.origin.x + measure.origin.x, y: system.origin.y + measure.origin.y)
                for element in measure.elements {
                    guard case let .rest(_, origin, _, restID, _) = element else { continue }
                    let point = CGPoint(x: base.x + origin.x, y: base.y + origin.y)
                    anchors.append((id: restID, point: point, sp: sp))
                }
            }
        }
        return anchors
    }

    // MARK: - 2 & 3. Caret + selection screen-frame publisher

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
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .animation(.snappy(duration: 0.15), value: host.caretItem)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { newValue in
                host.selectionScreenFrame = newValue
            }
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
        let (staff, measureIndex) = Self.staffAndMeasureIndex(of: item)
        guard let band = staffBand(for: staff, measureIndex: measureIndex) else { return nil }
        let sp = document.metrics.sp
        return (x: frame.minX - sp * 0.8, band: band)
    }

    /// `ScoreItemID`'s (staff, measureIndex) pair — every case carries both, directly or (a staff-default clef,
    /// which has no explicit measure) at the staff's opening measure.
    private static func staffAndMeasureIndex(of item: ScoreItemID) -> (staff: StaffAddress, measureIndex: Int) {
        switch item {
        case let .note(id): (id.staff, id.measureIndex)
        case let .rest(id): (id.staff, id.measureIndex)
        case let .tuplet(id): (id.staff, id.measureIndex)
        case let .clef(.explicit(id)): (id.staff, id.measureIndex)
        case let .clef(.staffDefault(staff)): (staff, 0)
        }
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

    // MARK: - 4 & 5. Pitch-drag handle + ghost notehead

    @ViewBuilder
    private var dragLayer: some View {
        if case let .single(.note(noteID)) = host.selection,
           let anchor = Self.noteheadAnchor(of: noteID, in: document)
        {
            let sp = document.metrics.sp
            Color.clear
                .contentShape(Circle())
                .frame(width: 44, height: 44)
                .position(anchor)
                // [verify] DragGesture(minimumDistance: 0) vs. the enclosing UIScrollView's pan recognizer needs
                // device-time confirmation that the drag reliably wins over scroll once the finger is down on the
                // handle. If it doesn't, fall back to `.simultaneousGesture` here plus an explicit `.onChanged`
                // guard that stops propagating translation to the scroll view.
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named("scoreSurface"))
                        .onChanged { value in
                            // One staff step (line <-> space) = sp / 2 in document coords; screen-up = pitch-up.
                            dragSteps = Int((-value.translation.height / (sp / 2)).rounded())
                        }
                        .onEnded { value in
                            let steps = Int((-value.translation.height / (sp / 2)).rounded())
                            dragSteps = nil
                            if steps != 0 { host.onPitchDragCommit(steps) }
                        },
                )
                .sensoryFeedback(.selection, trigger: dragSteps)

            if let steps = dragSteps {
                Ellipse()
                    .stroke(Color.accentColor, lineWidth: 1.5)
                    .frame(width: sp * 2.4, height: sp * 1.8)
                    .position(x: anchor.x, y: anchor.y - CGFloat(steps) * sp / 2)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    /// Document-space center of `noteID`'s notehead, found the same walk `ScoreHitTester.hitNote` uses
    /// (`ScoreHitTester.swift:193-214`) — including the notehead's `mirrorDx(stem:sp:)` offset (mirrored seconds are
    /// drawn on alternating sides of the stem).
    private static func noteheadAnchor(of noteID: NoteID, in document: LayoutDocument) -> CGPoint? {
        let sp = document.metrics.sp
        for system in document.systems {
            for measure in system.measures {
                let base = CGPoint(x: system.origin.x + measure.origin.x, y: system.origin.y + measure.origin.y)
                for element in measure.elements {
                    guard case let .chord(notes, _, stem, _, _, _, _, _, _, _, _) = element else { continue }
                    guard let note = notes.first(where: { $0.noteID == noteID }) else { continue }
                    let mirrorDx = note.mirrorDx(stem: stem, sp: sp)
                    return CGPoint(x: base.x + note.origin.x + mirrorDx, y: base.y + note.origin.y)
                }
            }
        }
        return nil
    }
}
