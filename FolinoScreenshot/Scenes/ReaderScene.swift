import Domain
import Reader
import ScreenshotKit
import SwiftUI

/// Marker class used to resolve the bundle that hosts `ScreenshotStrings.xcstrings`. See `LibraryScene` for the
/// rationale behind `.forClass` over `.atURL(Bundle.main.bundleURL)`.
private final class ScreenshotStringsAnchor {}

struct ReaderScene: View {
    @Environment(\.screenshotIdiom) private var idiom

    init() {
        // Runs before `body`, so the Reader observes page mode on first layout. Only one scene runs per app launch
        // (the dispatcher picks one by launch arg), so this never conflicts with HorizontalScene's `.horizontal` set.
        UserDefaults.standard.set(
            ReaderLayoutMode.page.rawValue,
            forKey: ReaderGlobalSettingsKey.layoutMode,
        )
    }

    var body: some View {
        ScreenshotFrameView(
            title: LocalizedStringResource(
                "scene.reader.title",
                table: "ScreenshotStrings",
                bundle: .forClass(ScreenshotStringsAnchor.self),
            ),
            subtitle: LocalizedStringResource(
                "scene.reader.subtitle",
                table: "ScreenshotStrings",
                bundle: .forClass(ScreenshotStringsAnchor.self),
            ),
            layout: FolinoScreenshotLayout.layout(for: idiom),
        ) {
            // ReaderRootScreen uses `.navigationTitle` / `.toolbar(.hidden,...)`, so it needs an ancestor nav container
            // but renders no visible bar of its own — the outer NavigationStack adds no doubled chrome.
            NavigationStack {
                ReaderRootScreen(
                    scoreItem: Fixture.items[0],
                    repository: FixtureScoreRepository(),
                    gateway: FixtureGateway(),
                    shareService: FixtureShareService(),
                    metadataReader: FixtureMetadataReader(),
                    scoresDirectory: URL(filePath: NSTemporaryDirectory()),
                    hidesBackButton: true,
                )
            }
        } overlay: {
            EmptyView()
        }
    }
}

#Preview(traits: .appStoreIPhone) {
    ReaderScene().environment(\.screenshotIdiom, .iPhone)
}
