#if DEBUG
import Domain
import SheetMusicCore
import SwiftUI

/// Verifies the page-mode inset wiring against a realistic score. Loads `Resources/PreviewAssets/Now_is_the_time.mscz`
/// (untracked by design — drop your own copy there) and falls back to `PreviewSampleScore.tall` so the build keeps
/// working without it.
@MainActor
private func paged(
    prefs: ReaderPreferences? = nil,
    staffSize: CGFloat = 7,
) -> some View {
    let score = PreviewBundledScore.nowIsTheTime() ?? PreviewSampleScore.tall
    let repo: any ScoreLibraryRepository = prefs.map { PreviewSeededPreferencesRepository(seededPreferences: $0) }
        ?? PreviewFakeRepository()
    let vm = ReaderViewModel(
        scoreItem: PreviewFakeRepository.sampleItem,
        repository: repo,
        gateway: PreviewFakeGateway(score: score),
        scoresDirectory: URL(filePath: "/tmp"),
    )
    return PagedScoreContainer(
        score: score,
        staffSize: staffSize,
        honorLayoutBreaks: false,
        collapseMultiMeasureRests: false,
        showInvisibleElements: false,
        playbackCursor: nil,
        transposeSemitones: 0,
        viewModel: vm,
    )
    .task { await vm.load() }
}

#Preview("Portrait · default insets") {
    paged(staffSize: 14)
        .background(Color.gray.opacity(0.4))
}

/// Mimics what `ReaderRootScreen` does: applies `safeAreaPadding(.top, ReaderTopOverlay.height)` on top of the device's
/// own status-bar / notch reserve. Without this the container's background reader sees only the simulated chrome and
/// subtracts the overlay height to zero, leaving an artificially small top inset.
private func underRootScreenChrome(_ statusBarTop: CGFloat) -> CGFloat {
    statusBarTop + ReaderTopOverlay.height
}

#Preview("Portrait · simulated iPhone notch") {
    paged()
        .background(Color.gray.opacity(0.4))
        .safeAreaPadding(.top, underRootScreenChrome(59))
        .safeAreaPadding(.bottom, 34)
        .background(Color.black)
}

#Preview("Landscape · simulated side insets") {
    paged()
        .background(Color.gray.opacity(0.4))
        .safeAreaPadding(.leading, 59)
        .safeAreaPadding(.trailing, 59)
        .safeAreaPadding(.top, underRootScreenChrome(0))
        .safeAreaPadding(.bottom, 21)
        .background(Color.black)
        .previewInterfaceOrientation(.landscapeRight)
}
#endif
