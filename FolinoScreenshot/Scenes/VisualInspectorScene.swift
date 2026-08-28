import Domain
@testable import Reader
import ScreenshotKit
import SwiftUI

/// Marker class used to resolve the bundle that hosts `ScreenshotStrings.xcstrings`. See `LibraryScene` for the
/// rationale behind `.forClass` over `.atURL(Bundle.main.bundleURL)`.
private final class ScreenshotStringsAnchor {}

/// The Visual inspector (layout direction / staff size / transpose / clefs) framed as a marketing shot. Uses
/// `@testable import Reader` for the same reason as `PlaybackInspectorScene`.
struct VisualInspectorScene: View {
    @Environment(\.screenshotIdiom) private var idiom

    @State private var viewModel = InspectorFixtureViewModel.make()

    init() {
        ScreenshotSetup.ensure()
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
                "scene.visualInspector.title",
                table: "ScreenshotStrings",
                bundle: .forClass(ScreenshotStringsAnchor.self),
            ),
            subtitle: LocalizedStringResource(
                "scene.visualInspector.subtitle",
                table: "ScreenshotStrings",
                bundle: .forClass(ScreenshotStringsAnchor.self),
            ),
            layout: FolinoScreenshotLayout.layout(
                for: idiom,
                subtitleBullet: true,
                // Match the faux status-bar band to whatever sits directly below it on each device, so the band reads
                // as part of the screen rather than a strip (same rule as `LibraryScene`). The iPhone gets the
                // inspector as a full sheet, so the band is grouped background; the iPad gets it as a popover over the
                // Reader, so the band is the Reader's white page.
                innerStatusBarColor: idiom.pick(
                    iPhone: Color(.systemGroupedBackground),
                    iPad: .white,
                ),
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
                // floating popover card anchored under the display-settings toolbar button (the right icon of the
                // inspector group in `ReaderToolbar`).
                ZStack(alignment: .topTrailing) {
                    readerBackground
                    IPadPopoverCard(arrowTrailingPadding: 10) {
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
        VisualInspectorScreen(
            layoutModel: viewModel.layoutModel,
            transposeModel: viewModel.transposeModel,
            score: Fixture.score,
        )
        .task { await viewModel.load() }
    }

    private var readerBackground: some View {
        NavigationStack {
            ReaderRootScreen(
                scoreItem: Fixture.items[0],
                repository: FixtureScoreRepository(),
                originalStore: FixtureOriginalStore(),
                gateway: FixtureGateway(),
                shareService: FixtureShareService(),
                vocalTunerHandoff: NoopVocalTunerHandoff(),
                metadataReader: FixtureMetadataReader(),
                annotationCoordinator: .fixture,
                scoresDirectory: URL(filePath: NSTemporaryDirectory()),
            )
        }
    }
}

#Preview("iPhone", traits: .appStoreIPhone) {
    VisualInspectorScene().environment(\.screenshotIdiom, .iPhone)
}

#Preview("iPad", traits: .appStoreIPad) {
    VisualInspectorScene().environment(\.screenshotIdiom, .iPad)
}
