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
        // Font provider + hint suppression — also here (not only in ScreenshotApp.init) so #Preview renders notation.
        ScreenshotSetup.ensure()
        // Runs before `body`, so the Reader observes vertical mode on first layout. Only one scene runs per app launch
        // (the dispatcher picks one by launch arg), so this never conflicts with HorizontalScene's `.horizontal` set.
        // Vertical (not page) so the notation also renders in SwiftUI `#Preview`; page-mode pagination only completes
        // in the live capture run, leaving the preview's score area empty.
        UserDefaults.standard.set(
            ReaderLayoutMode.vertical.rawValue,
            forKey: ReaderGlobalSettingsKey.layoutMode,
        )
        // "Seek bar off" — collapses the full seek card to the compact transport pill (small play button,
        // bottom-right) rather than removing playback chrome entirely.
        UserDefaults.standard.set(false, forKey: ReaderGlobalSettingsKey.showSeekBarEnabled)
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
            layout: FolinoScreenshotLayout.layout(
                for: idiom,
                subtitleBullet: true,
            ),
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
                    annotationStore: FixtureAnnotationStore(),
                    scoresDirectory: URL(filePath: NSTemporaryDirectory()),
                    hidesBackButton: true,
                )
            }
        } overlay: {
            EmptyView()
        }
    }
}

#Preview("iPhone", traits: .appStoreIPhone) {
    ReaderScene().environment(\.screenshotIdiom, .iPhone)
}

#Preview("iPad", traits: .appStoreIPad) {
    ReaderScene().environment(\.screenshotIdiom, .iPad)
}
