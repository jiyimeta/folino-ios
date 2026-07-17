import SheetMusicCore
import SheetMusicLayout
import SheetMusicUI
import SwiftUI

/// Long-press loupe (spec §5.2): magnifies the already-computed `document` 2x around `point` inside a 120 pt
/// glass-rimmed circle, so a dense chord's individual noteheads become distinguishable before the finger lifts and
/// commits a tap. Mounted by `EditingSelectionOverlay` while its long-press-then-drag sequence gesture is active;
/// this view only draws — it owns no gesture state itself.
struct EditingLoupeView: View {
    let document: LayoutDocument
    let score: Score
    /// The tracked finger position, in the same document (score-surface) coordinate space as `document` — the
    /// point that appears centered under the glass.
    let point: CGPoint

    private static let diameter: CGFloat = 120
    private static let magnification: CGFloat = 2

    var body: some View {
        ScoreView(document: document, score: score)
            // Explicit frame so the scale/offset math below is anchored to `document`'s own coordinate origin
            // rather than whatever intrinsic size SwiftUI infers for a raw `ScoreView` (mirrors the same pattern
            // `EditingSelectionOverlay.body` uses to stay in document coords).
                .frame(width: document.size.width, height: document.size.height, alignment: .topLeading)
                // Anchor the 2x scale at the document's top-leading origin (not the default center) so `point` maps to
                // `point * 2` in the scaled space regardless of the document's overall size — that's what makes the
                // offset below, expressed purely in terms of `point`, land it exactly at the loupe's center.
                .scaleEffect(Self.magnification, anchor: .topLeading)
                .offset(
                    x: Self.diameter / 2 - point.x * Self.magnification,
                    y: Self.diameter / 2 - point.y * Self.magnification,
                )
                .frame(width: Self.diameter, height: Self.diameter, alignment: .topLeading)
                .clipShape(Circle())
                .glassEffect(.regular, in: Circle())
                .allowsHitTesting(false)
                .accessibilityHidden(true)
    }
}

#if DEBUG
import SheetMusicLayoutApple

#Preview("Loupe · centered on a chord") {
    _ = SheetMusicLayoutApple.install
    let voice = Voice(elements: [
        .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
        .chord(Chord(duration: .quarter, notes: [
            Note(pitch: 60, tpc: 14), Note(pitch: 62, tpc: 16), Note(pitch: 64, tpc: 18),
        ])),
        .rest(duration: .quarter),
        .rest(duration: .quarter),
        .rest(duration: .quarter),
    ])
    let staff = Staff(measures: [Measure(voices: [voice])])
    let part = Part(id: "1", instrument: Instrument(id: "x"), staves: [staff])
    let score = Score(division: 480, parts: [part])
    let doc = LayoutEngine.layout(
        score: score,
        options: ScoreViewOptions(staffSize: 14, wrapToViewWidth: true),
        availableWidth: 700,
    )
    let chordAnchor = CGPoint(x: doc.systems[0].measures[0].origin.x + 40, y: doc.systems[0].origin.y + 20)
    return EditingLoupeView(document: doc, score: score, point: chordAnchor)
        .frame(width: 700, height: 300)
        .background(Color.gray.opacity(0.15))
}
#endif
