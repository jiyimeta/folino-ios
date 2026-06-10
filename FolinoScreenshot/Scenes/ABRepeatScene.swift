import Domain
@testable import Reader
import ScreenshotKit
import SwiftUI

/// Marker class used to resolve the bundle that hosts `ScreenshotStrings.xcstrings`. See `LibraryScene` for the
/// rationale behind `.forClass` over `.atURL(Bundle.main.bundleURL)`.
private final class ScreenshotStringsAnchor {}

/// The Playback inspector showcasing A–B repeat in its active state. Identical to `PlaybackInspectorScene` except the
/// global repeat mode is preset to `.abLoop` before the view model loads, so the repeat-mode row's picker label shows
/// the selected A–B state.
struct ABRepeatScene: View {
    @Environment(\.screenshotIdiom) private var idiom

    @State private var viewModel = InspectorFixtureViewModel.make()

    init() {
        ScreenshotSetup.ensure()
        // Preset the global, sticky repeat mode to A–B *before* `body` runs. `RepeatModel.sync(from:)` (called inside
        // `viewModel.load()`) re-reads this same global key, so the loaded model lands on `.abLoop` and the repeat-mode
        // picker renders its active state. Writing through `RepeatModeStorage` is exactly what the inspector's
        // `@AppStorage(ReaderGlobalSettingsKey.repeatMode)` binding does.
        RepeatModeStorage.set(.abLoop)
    }

    var body: some View {
        ScreenshotFrameView(
            title: LocalizedStringResource(
                "scene.abRepeat.title",
                table: "ScreenshotStrings",
                bundle: .forClass(ScreenshotStringsAnchor.self),
            ),
            subtitle: LocalizedStringResource(
                "scene.abRepeat.subtitle",
                table: "ScreenshotStrings",
                bundle: .forClass(ScreenshotStringsAnchor.self),
            ),
            layout: FolinoScreenshotLayout.layout(
                for: idiom,
                innerStatusBarColor: Color(.systemGroupedBackground),
            ),
        ) {
            NavigationStack {
                PlaybackInspectorScreen(
                    mixerModel: viewModel.mixerModel,
                    tempoModel: viewModel.tempoModel,
                    masterVolumeModel: viewModel.masterVolumeModel,
                    a4ReferenceModel: viewModel.a4ReferenceModel,
                    repeatModel: viewModel.repeatModel,
                    transposeModel: viewModel.transposeModel,
                    score: Fixture.score,
                    playbackCursor: nil,
                    isInPlaylist: true,
                )
                .task { await viewModel.load() }
            }
        } overlay: {
            EmptyView()
        }
    }
}

#Preview(traits: .appStoreIPhone) {
    ABRepeatScene().environment(\.screenshotIdiom, .iPhone)
}
