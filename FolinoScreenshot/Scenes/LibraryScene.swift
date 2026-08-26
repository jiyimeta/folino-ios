import Domain
import Library
import Reader
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

    init() {
        // The iPad split-view detail hosts a live Reader, so mirror ReaderScene's setup: register the notation font
        // (also done in ScreenshotApp.init, but repeated here so the detail's notation renders in SwiftUI `#Preview`)
        // and pin vertical layout / compact transport so the detail looks like the production Reader. No-op for the
        // iPhone single-column branch, which renders no Reader.
        ScreenshotSetup.ensure()
        UserDefaults.standard.set(
            ReaderLayoutMode.vertical.rawValue,
            forKey: ReaderGlobalSettingsKey.layoutMode,
        )
        UserDefaults.standard.set(false, forKey: ReaderGlobalSettingsKey.showSeekBarEnabled)
    }

    var body: some View {
        ScreenshotSceneFrame(
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
                // iPhone shows the grouped library list under the status bar. iPad shows the split-view detail (the
                // Reader), which `.prominentDetail` dims to ~80% brightness while the sidebar is up — sampled from the
                // rendered preview as #CCCCCC (white × ~0.8). Match the faux status-bar band to whatever sits directly
                // below it on each device so the band reads as part of the screen, not a strip.
                innerStatusBarColor: idiom.pick(
                    iPhone: Color(.systemGroupedBackground),
                    iPad: Color(white: 0.8),
                ),
            ),
            idiom: idiom,
        ) {
            switch idiom {
            case .iPhone:
                iPhoneLibrary
            case .iPad:
                iPadLibrary
            }
        } overlay: {
            EmptyView()
        }
    }

    /// iPhone: the single-column library list (compact size class), matching `AppShellView`'s compact branch.
    private var iPhoneLibrary: some View {
        LibraryRootScreen(
            viewModel: makeLibraryViewModel(),
            path: .constant(NavigationPath()),
            onOpenScore: { _ in },
            readerDestination: { _ in EmptyView() },
            playlistReaderDestination: { _ in EmptyView() },
            onOpenInPlaylist: { _, _ in },
            licenseContent: { EmptyView() },
        )
    }

    /// iPad: the sidebar + detail split view (regular size class), mirroring `AppShellView`'s regular branch — the
    /// library list lives in the sidebar and a score is opened in the prominent detail column.
    private var iPadLibrary: some View {
        NavigationSplitView(columnVisibility: .constant(.doubleColumn)) {
            LibraryRootScreen(
                viewModel: makeLibraryViewModel(),
                path: .constant(NavigationPath()),
                onOpenScore: { _ in },
                readerDestination: { _ in EmptyView() },
                playlistReaderDestination: { _ in EmptyView() },
                onOpenInPlaylist: { _, _ in },
                licenseContent: { EmptyView() },
            )
            // The real sidebar is a frosted panel over the detail. `drawHierarchy` can't reproduce backdrop blur (see
            // `ScreenshotCaptureSession`), so without an opaque backing the score behind it comes through sharp and
            // the list reads as printed on top of the music. Substitute the material's resting tint.
            .background(Color(.systemGroupedBackground))
                .navigationSplitViewColumnWidth(min: 350, ideal: 420)
        } detail: {
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
        .navigationSplitViewStyle(.prominentDetail)
    }

    private func makeLibraryViewModel() -> LibraryViewModel {
        LibraryViewModel(
            repository: FixtureScoreRepository(),
            originalStore: FixtureOriginalStore(),
            importer: FixtureImporter(),
            gateway: FixtureGateway(),
            shareService: FixtureShareService(),
            metadataReader: FixtureMetadataReader(),
            creator: FixtureCreator(),
            // Same throwaway location the detail Reader above uses. No screenshot scene drives creation or the
            // wizard's clone step, so nothing ever resolves a file under it.
            scoresDirectory: URL(filePath: NSTemporaryDirectory()),
        )
    }
}

#Preview("iPhone", traits: .appStoreIPhone) {
    LibraryScene().environment(\.screenshotIdiom, .iPhone)
}

#Preview("iPad", traits: .appStoreIPad) {
    LibraryScene().environment(\.screenshotIdiom, .iPad)
}
