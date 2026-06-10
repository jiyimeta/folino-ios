import Domain
@testable import Reader
import ScreenshotKit
import SwiftUI

/// Marker class used to resolve the bundle that hosts `ScreenshotStrings.xcstrings`. See `LibraryScene` for the
/// rationale behind `.forClass` over `.atURL(Bundle.main.bundleURL)`.
private final class ScreenshotStringsAnchor {}

/// The Playback inspector (mixer / tempo / tuning / repeat) framed as a marketing shot. These screens + their models +
/// `ReaderViewModel` are `internal` to the Reader package, so this scene uses `@testable import Reader` — the
/// FolinoScreenshot target builds Debug, so testability is available (mirrors the project's existing convention).
///
/// The inspector's "Parts" section reads `score.parts` directly (passed separately), so it populates from
/// `Fixture.score` immediately; the "General" section reads the sub-models, seeded by `await viewModel.load()`
/// (driven in `.task` for the real capture) and otherwise showing sensible defaults — either way the panel renders.
struct PlaybackInspectorScene: View {
    @Environment(\.screenshotIdiom) private var idiom

    @State private var viewModel = InspectorFixtureViewModel.make()

    init() {
        // Font provider + hint suppression — also here (not only in ScreenshotApp.init) so #Preview renders the panel.
        ScreenshotSetup.ensure()
        // The repeat mode is a global, sticky UserDefault shared with the ABRepeat scene. Pin it to `.off` here so this
        // panel shows a neutral repeat state (and doesn't inherit `.abLoop` left persisted by a prior ABRepeat launch),
        // differentiating it from the ABRepeat scene regardless of capture order.
        RepeatModeStorage.set(.off)
    }

    var body: some View {
        ScreenshotFrameView(
            title: LocalizedStringResource(
                "scene.playbackInspector.title",
                table: "ScreenshotStrings",
                bundle: .forClass(ScreenshotStringsAnchor.self),
            ),
            subtitle: LocalizedStringResource(
                "scene.playbackInspector.subtitle",
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
    PlaybackInspectorScene().environment(\.screenshotIdiom, .iPhone)
}
