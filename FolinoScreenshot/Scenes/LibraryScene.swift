import Domain
import Library
import ScreenshotKit
import SwiftUI

/// Marker class used to resolve the bundle that hosts `ScreenshotStrings.xcstrings`.
/// `.forClass` anchors the lookup to this app target's bundle directly, which is
/// more robust than `.atURL(Bundle.main.bundleURL)` for the `String(localized:)`
/// resolution path. Note: the catalog only ships `en`, and `String(localized:)`
/// (used for the subtitle in ScreenshotFrameView) honors the active locale
/// strictly without development-language fallback — so non-en runs need the
/// catalog localized or the app launched with an `en` locale override.
private final class ScreenshotStringsAnchor {}

struct LibraryScene: View {
    @Environment(\.screenshotIdiom) private var idiom

    var body: some View {
        ScreenshotFrameView(
            title: LocalizedStringResource(
                "scene.library.title",
                table: "ScreenshotStrings",
                bundle: .forClass(ScreenshotStringsAnchor.self),
            ),
            subtitle: LocalizedStringResource(
                "scene.library.subtitle",
                table: "ScreenshotStrings",
                bundle: .forClass(ScreenshotStringsAnchor.self),
            ),
            layout: FolinoScreenshotLayout.layout(
                for: idiom,
                subtitleBullet: true,
                innerStatusBarColor: Color(.systemGroupedBackground),
            ),
        ) {
            LibraryRootScreen(
                viewModel: LibraryViewModel(
                    repository: FixtureScoreRepository(),
                    importer: FixtureImporter(),
                    gateway: FixtureGateway(),
                    shareService: FixtureShareService(),
                    metadataReader: FixtureMetadataReader(),
                ),
                path: .constant(NavigationPath()),
                onOpenScore: { _ in },
                readerDestination: { _ in EmptyView() },
                playlistReaderDestination: { _ in EmptyView() },
                onOpenInPlaylist: { _, _ in },
                licenseContent: { EmptyView() },
            )
        } overlay: {
            EmptyView()
        }
    }
}

#Preview(traits: .appStoreIPhone) {
    LibraryScene().environment(\.screenshotIdiom, .iPhone)
}
