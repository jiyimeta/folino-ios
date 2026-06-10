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
    }

    var body: some View {
        ScreenshotFrameView(
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
                innerStatusBarColor: Color(.systemGroupedBackground),
            ),
        ) {
            NavigationStack {
                VisualInspectorScreen(
                    layoutModel: viewModel.layoutModel,
                    transposeModel: viewModel.transposeModel,
                    score: Fixture.score,
                )
                .task { await viewModel.load() }
            }
        } overlay: {
            EmptyView()
        }
    }
}

#Preview(traits: .appStoreIPhone) {
    VisualInspectorScene().environment(\.screenshotIdiom, .iPhone)
}
