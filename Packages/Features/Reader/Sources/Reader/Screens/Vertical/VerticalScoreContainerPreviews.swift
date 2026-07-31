#if DEBUG
import Domain
import SheetMusicCore
import SwiftUI

// Verifies the initial scroll position lands at the *top* of the score — used to confirm the
// `.defaultScrollAnchor(.topLeading)` fix in `VerticalScoreContainer`. Without the modifier this preview opens around
// the middle of the score because the container's content grows from `Color.clear` (size 0×0 while `document == nil`)
// to the laid-out page once `rebuildLayout` finishes, and SwiftUI's default 2-axis scroll anchor preserves the *centre*
// across content-size changes.
#Preview("Initial scroll · top of score") {
    let score = PreviewSampleScore.tall
    let repo = PreviewFakeRepository()
    let vm = ReaderViewModel(
        scoreItem: PreviewFakeRepository.sampleItem,
        repository: repo,
        gateway: PreviewFakeGateway(score: score),
        scoresDirectory: URL(filePath: "/tmp"),
    )
    VerticalScoreContainer(
        score: score,
        staffSize: 14,
        honorLayoutBreaks: false,
        collapseMultiMeasureRests: false,
        showInvisibleElements: false,
        playbackCursor: nil,
        scrollAnchorCursor: nil,
        autoFollowEnabled: true,
        transposeSemitones: 0,
        editingScoreVersion: 0,
        bottomControlClearance: ReaderTransportControl.expandedContentHeight,
        viewModel: vm,
    )
    .frame(width: 600, height: 500)
}

// MARK: - A–B loop boundary marker previews

/// Builds the shared boilerplate for A–B marker preview blocks: score, repo, view model, and container — differing only
/// in the seeded `ReaderPreferences`.
@MainActor
private func abLoopPreview(prefs: ReaderPreferences) -> some View {
    let score = PreviewSampleScore.tall
    let repo = PreviewSeededPreferencesRepository(seededPreferences: prefs)
    let vm = ReaderViewModel(
        scoreItem: PreviewFakeRepository.sampleItem,
        repository: repo,
        gateway: PreviewFakeGateway(score: score),
        scoresDirectory: URL(filePath: "/tmp"),
    )
    // Markers appear after load() seeds preferences; first frame renders without them.
    return VerticalScoreContainer(
        score: score,
        staffSize: 14,
        honorLayoutBreaks: false,
        collapseMultiMeasureRests: false,
        showInvisibleElements: false,
        playbackCursor: nil,
        scrollAnchorCursor: nil,
        autoFollowEnabled: true,
        transposeSemitones: 0,
        editingScoreVersion: 0,
        bottomControlClearance: ReaderTransportControl.expandedContentHeight,
        viewModel: vm,
    )
    .frame(width: 600, height: 500)
    .task { await vm.load() }
}

#Preview("A–B markers · multi-bar") {
    // Pre-seed an A–B loop spanning a few bars. ChordPath only needs the indices the overlay reads — markers gate on
    // measureIndex, so chordIndex/voiceIndex/systemIndex can stay at 0.
    let item = PreviewFakeRepository.sampleItem
    let prefs = ReaderPreferences(
        scoreItemID: item.id,
        staffSize: 14,
        hiddenStaves: [],
        repeatMode: .abLoop,
        abRepeat: ABRepeatRange(
            start: ChordPath(systemIndex: 0, measureIndex: 1, voiceIndex: 0, chordIndex: 0),
            end: ChordPath(systemIndex: 0, measureIndex: 3, voiceIndex: 0, chordIndex: 0),
        ),
    )
    abLoopPreview(prefs: prefs)
}

#Preview("A–B markers · same measure") {
    let item = PreviewFakeRepository.sampleItem
    let p = ChordPath(systemIndex: 0, measureIndex: 2, voiceIndex: 0, chordIndex: 0)
    let prefs = ReaderPreferences(
        scoreItemID: item.id,
        staffSize: 14,
        hiddenStaves: [],
        repeatMode: .abLoop,
        abRepeat: ABRepeatRange(start: p, end: p),
    )
    abLoopPreview(prefs: prefs)
}
#endif
