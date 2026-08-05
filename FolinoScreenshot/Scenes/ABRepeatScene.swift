import Domain
@testable import Reader
import ScreenshotKit
import SwiftUI

/// Marker class used to resolve the bundle that hosts `ScreenshotStrings.xcstrings`. See `LibraryScene` for the
/// rationale behind `.forClass` over `.atURL(Bundle.main.bundleURL)`.
private final class ScreenshotStringsAnchor {}

/// The Reader showcasing an active A–B repeat region. Same vertical-layout Reader as `ReaderScene`, but the global
/// repeat mode is preset to `.abLoop` and the score's `ReaderPreferences` carry an A–B range spanning the user-facing
/// measures 5–7, so the translucent loop band (`LoopRegionOverlay`) renders over those measures.
struct ABRepeatScene: View {
    @Environment(\.screenshotIdiom) private var idiom

    /// User-facing measures 5–7 → 0-based `measureIndex` 4…6. `LoopRegionOverlay` fills every layout measure whose
    /// `measureIndex` is in `[start.measureIndex, end.measureIndex]`; only `measureIndex` matters for the band (the
    /// `chordIndex` endpoints affect playback, not the overlay), so the start head / end head both use chord 0.
    private static let abRange = ABRepeatRange(
        start: ChordPath(systemIndex: 0, measureIndex: 4, voiceIndex: 0, chordIndex: 0),
        end: ChordPath(systemIndex: 0, measureIndex: 6, voiceIndex: 0, chordIndex: 0),
    )

    private let repository: FixtureScoreRepository

    init() {
        // Font provider + hint suppression — also here (not only in ScreenshotApp.init) so #Preview renders notation.
        ScreenshotSetup.ensure()
        // Vertical (not page) so the notation also renders in SwiftUI `#Preview`; page-mode pagination only
        // completes in the live capture run. Matches `ReaderScene`.
        UserDefaults.standard.set(
            ReaderLayoutMode.vertical.rawValue,
            forKey: ReaderGlobalSettingsKey.layoutMode,
        )
        // "Seek bar off" — collapses the full seek card to the compact transport pill rather than removing playback
        // chrome entirely. Matches `ReaderScene`.
        UserDefaults.standard.set(false, forKey: ReaderGlobalSettingsKey.showSeekBarEnabled)
        // Preset the global, sticky repeat mode to A–B *before* `body` runs. `RepeatModel.sync(from:)` (called inside
        // `viewModel.load()`) reads this same global key for the mode, so the loaded model lands on `.abLoop` and the
        // active loop range (the per-score `abRepeat`) is honored.
        RepeatModeStorage.set(.abLoop)

        // Seed the score's per-score Reader preferences with the A–B range. `ReaderViewModel.load()` →
        // `ReaderPreferencesStore.loadOrSeed()` → `repository.loadReaderPreferences(for:)` returns this, then
        // `repeatModel.sync(from:)` copies `abRepeat` into `RepeatModel.abRange`, which `LoopRegionOverlay` draws.
        let scoreItemID = Fixture.items[0].id
        let prefs = ReaderPreferences(
            scoreItemID: scoreItemID,
            // Match the Reader's default engraved staff size (`ReaderViewModel.defaultStaffSize`) so the notation
            // renders at the same scale as `ReaderScene` — these are stored prefs, not the seed-defaults path.
            staffSize: 14,
            hiddenStaves: [],
            repeatMode: .abLoop,
            abRepeat: Self.abRange,
        )
        repository = FixtureScoreRepository(readerPreferences: [scoreItemID: prefs])
    }

    var body: some View {
        ScreenshotSceneFrame(
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
            layout: FolinoScreenshotLayout.layout(for: idiom),
            idiom: idiom,
        ) {
            // ReaderRootScreen puts its controls in a real `.toolbar`, so it needs an ancestor nav container to host
            // them. The bar's own background is hidden, so the outer NavigationStack adds no doubled chrome.
            NavigationStack {
                ReaderRootScreen(
                    scoreItem: Fixture.items[0],
                    repository: repository,
                    gateway: FixtureGateway(),
                    shareService: FixtureShareService(),
                    vocalTunerHandoff: NoopVocalTunerHandoff(),
                    metadataReader: FixtureMetadataReader(),
                    annotationCoordinator: .fixture,
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
    ABRepeatScene().environment(\.screenshotIdiom, .iPhone)
}

#Preview("iPad", traits: .appStoreIPad) {
    ABRepeatScene().environment(\.screenshotIdiom, .iPad)
}
