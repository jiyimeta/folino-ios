import CoreGraphics
import Foundation
@testable import Reader
import SheetMusicCore
import SheetMusicLayout
import Testing

/// The reader hands every re-engrave to one long-lived `ScoreRelayoutEngine` so consecutive edits can reuse the
/// engine's `LayoutCache`. A cache is only ever a speed-up if it is invisible: these tests pin that the engraving a
/// reused cache produces is byte-for-byte what a cold, cache-less `LayoutEngine.layout` produces for the same inputs.
///
/// The inputs exercised are the ones the reader actually varies between calls on a single surface — an edited
/// measure, a resized viewport, and toggled `ScoreViewOptions` — i.e. exactly the places a stale entry could survive.
@Suite("ScoreRelayoutEngine")
struct ScoreRelayoutEngineTests {
    /// Install the CoreText FontMetrics provider so `LayoutEngine`'s precondition passes.
    private let _install: Void = LayoutTestSupport.installed

    // MARK: - Fixtures

    /// A score long enough to wrap into several systems (so the per-SYSTEM cache is exercised, not just per-measure)
    /// and wide enough to have two staves that must agree on tick columns.
    private func score(measureCount: Int = 24, pitchAt: (Int) -> Int = { 60 + $0 % 12 }) -> Score {
        let staves = (0 ..< 2).map { staffIdx in
            Staff(measures: (0 ..< measureCount).map { idx in
                let elements: [VoiceElement] = (0 ..< 4).map { beat in
                    let pitch = pitchAt(idx * 4 + beat + staffIdx * 7)
                    return .chord(Chord(duration: .quarter, notes: [Note(pitch: pitch, tpc: 14)]))
                }
                return Measure(voices: [Voice(elements: elements)])
            })
        }
        return Score(
            division: 480,
            parts: staves.enumerated().map { idx, staff in
                Part(id: "P\(idx)", instrument: Instrument(id: "inst"), staves: [staff])
            },
        )
    }

    /// Replace one note in one measure — the shape of a single keystroke in the note-editing pad.
    private func editing(_ score: Score, measure: Int, toPitch pitch: Int) -> Score {
        var parts = score.parts
        var measures = parts[0].staves[0].measures
        var voices = measures[measure].voices
        var elements = voices[0].elements
        elements[0] = .chord(Chord(duration: .quarter, notes: [Note(pitch: pitch, tpc: 14)]))
        voices[0] = Voice(elements: elements)
        measures[measure] = Measure(
            voices: voices,
            lineBreak: measures[measure].lineBreak,
            pageBreak: measures[measure].pageBreak,
        )
        parts[0].staves[0] = Staff(measures: measures)
        return Score(
            division: score.division, parts: parts, metaTags: score.metaTags,
            titleFrame: score.titleFrame, style: score.style,
        )
    }

    private func uncached(
        _ score: Score, options: ScoreViewOptions, width: CGFloat,
    ) -> LayoutDocument {
        LayoutEngine.layout(score: score, options: options, availableWidth: width)
    }

    // MARK: - Tests

    @Test
    func `a run of single-measure edits engraves exactly as a cold layout would`() async {
        let engine = ScoreRelayoutEngine()
        let options = ScoreViewOptions()
        let width: CGFloat = 700

        var current = score()
        _ = await engine.layout(score: current, options: options, availableWidth: width)

        // Walk the edit across systems, not just within the first one: an entry that went stale would only show up
        // once the edit moved off the measures the first call happened to rebuild.
        for measure in [0, 5, 5, 17, 23] {
            current = editing(current, measure: measure, toPitch: 55 + measure)
            let cached = await engine.layout(score: current, options: options, availableWidth: width)
            #expect(cached == uncached(current, options: options, width: width))
        }
    }

    @Test
    func `a width change re-engraves rather than serving the previous width's systems`() async {
        let engine = ScoreRelayoutEngine()
        let options = ScoreViewOptions()
        let subject = score()

        _ = await engine.layout(score: subject, options: options, availableWidth: 700)
        for width in [420, 1000, 700] as [CGFloat] {
            let cached = await engine.layout(score: subject, options: options, availableWidth: width)
            #expect(cached == uncached(subject, options: options, width: width))
        }
    }

    @Test
    func `an options change re-engraves rather than serving the previous options' systems`() async {
        let engine = ScoreRelayoutEngine()
        let width: CGFloat = 700
        let subject = score()

        var options = ScoreViewOptions()
        _ = await engine.layout(score: subject, options: options, availableWidth: width)

        options.staffSize *= 1.5
        #expect(
            await engine.layout(score: subject, options: options, availableWidth: width)
                == uncached(subject, options: options, width: width),
        )

        options.showsInvisibleElements.toggle()
        #expect(
            await engine.layout(score: subject, options: options, availableWidth: width)
                == uncached(subject, options: options, width: width),
        )
    }

    @Test
    func `horizontal mode engraves at the score's natural width, incrementally`() async {
        let engine = ScoreRelayoutEngine()
        let options = ScoreViewOptions(wrapToViewWidth: false, includeTitleFrame: false)

        var current = score()
        _ = await engine.layoutAtNaturalWidth(score: current, options: options)

        for measure in [3, 3, 19] {
            current = editing(current, measure: measure, toPitch: 62 + measure)
            let cached = await engine.layoutAtNaturalWidth(score: current, options: options)
            let natural = LayoutEngine.naturalContentWidth(score: current, options: options)
            #expect(cached == uncached(current, options: options, width: natural))
        }
    }
}
