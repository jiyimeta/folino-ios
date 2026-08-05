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
        // iPad presents this inspector as a popover over the Reader; pin the background Reader to vertical layout /
        // compact transport so its notation renders in `#Preview` (same rationale as ReaderScene). No-op on iPhone.
        UserDefaults.standard.set(
            ReaderLayoutMode.vertical.rawValue,
            forKey: ReaderGlobalSettingsKey.layoutMode,
        )
        UserDefaults.standard.set(false, forKey: ReaderGlobalSettingsKey.showSeekBarEnabled)
    }

    var body: some View {
        ScreenshotSceneFrame(
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
                subtitleBullet: true,
                innerStatusBarColor: Color(.systemGroupedBackground),
            ),
            idiom: idiom,
        ) {
            switch idiom {
            case .iPhone:
                // iPhone: the inspector adapts to a full sheet, so render the panel full-bleed.
                NavigationStack {
                    inspector
                }
            case .iPad:
                // iPad: the inspector is a popover over the Reader — show the Reader behind, with the panel as a
                // floating popover card anchored under the playback-settings toolbar button (the left icon of the
                // inspector group in `ReaderToolbar`).
                ZStack(alignment: .topTrailing) {
                    readerBackground
                    IPadPopoverCard(arrowTrailingPadding: 54) {
                        NavigationStack {
                            inspector
                        }
                    }
                    .padding(.top, 56)
                    .padding(.trailing, 14)
                }
            }
        } overlay: {
            EmptyView()
        }
    }

    private var inspector: some View {
        PlaybackInspectorScreen(
            mixerModel: viewModel.mixerModel,
            layoutModel: viewModel.layoutModel,
            tempoModel: viewModel.tempoModel,
            masterVolumeModel: viewModel.masterVolumeModel,
            a4ReferenceModel: viewModel.a4ReferenceModel,
            repeatModel: viewModel.repeatModel,
            transposeModel: viewModel.transposeModel,
            score: Fixture.score,
            // The fixture view model's own session: nothing is loaded into it, so it stays stopped with no cursor —
            // which is what this panel should show.
            playbackSession: viewModel.playbackSession,
            isInPlaylist: true,
        )
        .task { await viewModel.load() }
    }

    private var readerBackground: some View {
        NavigationStack {
            ReaderRootScreen(
                scoreItem: Fixture.items[0],
                repository: FixtureScoreRepository(),
                gateway: FixtureGateway(),
                shareService: FixtureShareService(),
                vocalTunerHandoff: NoopVocalTunerHandoff(),
                metadataReader: FixtureMetadataReader(),
                annotationCoordinator: .fixture,
                scoresDirectory: URL(filePath: NSTemporaryDirectory()),
                hidesBackButton: true,
            )
        }
    }
}

#Preview("iPhone", traits: .appStoreIPhone) {
    PlaybackInspectorScene().environment(\.screenshotIdiom, .iPhone)
}

#Preview("iPad", traits: .appStoreIPad) {
    PlaybackInspectorScene().environment(\.screenshotIdiom, .iPad)
}
