#if DEBUG
import Domain
import SheetMusicCore
import SwiftUI

/// Three quarter-rests-per-measure score so AB-loop endpoints can snap to a chord (`snapMeasureEnd` needs at least one
/// `.chord` — rests count). Empty measures would let `setA` work but not `setB`. With `includeMarks` false the score
/// carries no rehearsal marks, so the seek card omits the mark bar — used to confirm the time readout (anchored to the
/// seek bar) stays put whether or not marks are present.
@MainActor
private func transportPreviewViewModel(includeMarks: Bool = true) -> ReaderViewModel {
    let restChords = Array(
        repeating: VoiceElement.chord(Chord(duration: .quarter, notes: [])),
        count: 4,
    )
    let restMeasure = Measure(voices: [Voice(elements: restChords)])
    /// Rehearsal marks on measures 0 and 2 — one short, one long (to exercise truncation) — so the mark bubbles render.
    func marked(_ text: String) -> SystemMeasure {
        SystemMeasure(elements: [
            PositionedSystemElement(position: .start, element: .rehearsalMark(RehearsalMark(text: text))),
        ])
    }
    let score = Score(
        division: 480,
        parts: [
            Part(
                id: "P0",
                instrument: Instrument(id: "i", channels: [InstrumentChannel(program: 0)]),
                staves: [Staff(measures: [restMeasure, restMeasure, restMeasure])],
            ),
        ],
        systemMeasures: includeMarks ? [marked("A"), SystemMeasure(), marked("B — Chorus, softer")] : [],
        metaTags: [:],
    )
    return ReaderViewModel(
        scoreItem: PreviewFakeRepository.sampleItem,
        repository: PreviewFakeRepository(),
        gateway: PreviewFakeGateway(score: score),
        scoresDirectory: URL(filePath: "/tmp"),
    )
}

/// Puts the control into AB-loop with only the A endpoint set, so the A/B pill shows its split state (A set, B unset).
@MainActor
private func configureTransportPreview(_ vm: ReaderViewModel) async {
    await vm.load()
    vm.repeatModel.mode = .abLoop
    vm.playbackSession.setManualCursor(.beat(measureIndex: 1, tickInMeasure: 0))
    await vm.repeatModel.setA()
}

#Preview("Transport control · seek bar") {
    let vm = transportPreviewViewModel()
    return VStack(spacing: 0) {
        Color.clear.border(.orange)
        ReaderTransportControl(viewModel: vm, showSeekBar: true)
    }
    .task { await configureTransportPreview(vm) }
}

#Preview("Transport control · seek bar (no marks)") {
    let vm = transportPreviewViewModel(includeMarks: false)
    return VStack(spacing: 0) {
        Color.clear.border(.orange)
        ReaderTransportControl(viewModel: vm, showSeekBar: true)
    }
    .task { await configureTransportPreview(vm) }
}

#Preview("Transport control · collapsed") {
    let vm = transportPreviewViewModel()
    return VStack(spacing: 0) {
        Color.clear.border(.orange)
        ReaderTransportControl(viewModel: vm, showSeekBar: false)
    }
    .task { await configureTransportPreview(vm) }
}
#endif
