import Domain
import Reader
import ScreenshotKit
import SwiftUI

/// Marker class used to resolve the bundle that hosts `ScreenshotStrings.xcstrings`. See `LibraryScene` for the
/// rationale behind `.forClass` over `.atURL(Bundle.main.bundleURL)`.
private final class ScreenshotStringsAnchor {}

/// Marketing shot for note editing: the live editing surface with a note selected — its callout beside it, the input
/// pad up, and the header's voice / undo / 完了 cluster in place.
///
/// Everything here is the REAL app: `EditableReaderScreen` is the same composition-root wrapper `AppShellView` uses,
/// so the Reader, the seam and the Editor's chrome are wired exactly as they are in production. Only the services
/// underneath are fixtures.
///
/// Two states can't be reached the way a user reaches them — the capture harness draws a scene out of a window rather
/// than driving the app, so there is nobody to press the edit button or tap a note. Both are seeded through the same
/// switches the app already has:
///  - `readerAutoEditMeasure` makes the Reader open an edit session on that measure's first note once the score has
///    loaded (see `ReaderRootScreen.startScreenshotEditingIfRequested`);
///  - `editorPadVisible` is the Editor chrome's own `@AppStorage` for the pad — expanded is the default, but the
///    scene pins it anyway so a device that once tucked the pad can't capture a padless shot.
struct NoteEditingScene: View {
    @Environment(\.screenshotIdiom) private var idiom

    /// Which measure the selected note comes from — bar 2, the first one with sung notes in it. Not bar 1 (clef, key
    /// and time signature, every part but the percussion resting), and not a later bar however good it looks: the
    /// score opens at the top and the capture can't scroll, so the note has to be in the opening screenful or the
    /// callout ends up clamped at the bottom edge pointing off-screen.
    private static let editedMeasureIndex = 3

    /// Engraved staff size for this scene, against the Reader's default of 14. Editing is a shot about ONE note — the
    /// tinted notehead, the callout beside it, the length its keys are showing — and at the reading default those are
    /// a few pixels each in a thumbnail.
    private static let staffSize: Double = 24

    /// Which parts of the fixture score to put away, per idiom — the Reader's own part-visibility feature rather
    /// than a screenshot trick, and one that now survives an edit session: the surface renders the filtered score
    /// while the Editor keeps working in full-score addresses, with the host re-stamping selection and caret between
    /// the two.
    ///
    /// The phone keeps one part. The fixture is a six-part vocal arrangement, and six staves on a 440 pt-wide page
    /// leave each note a few pixels of a thumbnail — while its opening bar rests in all but the percussion, so an
    /// unfiltered phone shot leads with a screenful of empty staves.
    ///
    /// The iPad keeps all six, which is the opposite call for the same reason: it is two and a half times as wide,
    /// so a lone melody line comes out as eight near-identical systems of "tu tu tu" — thin where the phone's
    /// version is legible. The full arrangement gives that canvas something to be.
    private static func hiddenStaves(for idiom: ScreenshotIdiom) -> Set<StaffAddress> {
        idiom.pick(
            iPhone: Set([0, 2, 3, 4, 5].map { StaffAddress(partIndex: $0, staffIndexInPart: 0) }),
            iPad: [],
        )
    }

    private let repository: FixtureScoreRepository

    /// One instance for the process, not one per `body`. `ProcessScoreEditHistoryStore` installs a `.default`
    /// NotificationCenter observer it never removes — correct only for the process-lifetime singleton the app
    /// composes in `AppBootstrap`, and a leak per body evaluation if built inline here.
    @MainActor private static let historyStore = ProcessScoreEditHistoryStore()

    init() {
        ScreenshotSetup.ensure()
        // Vertical for the same reason as `ReaderScene`: the notation also renders in `#Preview`, which page mode's
        // pagination never finishes in. It is also the mode the pad suits — a bottom-docked pad turns into scroll
        // padding here, where in page mode it would re-paginate the score.
        UserDefaults.standard.set(ReaderLayoutMode.vertical.rawValue, forKey: ReaderGlobalSettingsKey.layoutMode)
        // Edit mode collapses the seek card to the compact pill anyway; pinning it keeps the two agreeing.
        UserDefaults.standard.set(false, forKey: ReaderGlobalSettingsKey.showSeekBarEnabled)
        UserDefaults.standard.set(true, forKey: ScreenshotEditingKey.padVisible)
        UserDefaults.standard.set(Self.editedMeasureIndex, forKey: ScreenshotEditingKey.autoEditMeasure)

        // Per-score prefs rather than a global: staff size is stored per score item, and `ReaderViewModel.load()`
        // seeds from the repository (see `ABRepeatScene`, which seeds its loop range the same way).
        let scoreItemID = Fixture.items[0].id
        repository = FixtureScoreRepository(readerPreferences: [
            scoreItemID: ReaderPreferences(
                scoreItemID: scoreItemID,
                staffSize: Self.staffSize,
                hiddenStaves: Self.hiddenStaves(for: ScreenshotEnvironment.idiom),
                // Ignore the authored breaks so bar 1 doesn't get a system to itself. It is an intro bar every part
                // rests through, and honoring the break parked a screenful of empty staves at the top and pushed the
                // edited note down into the pad's half of the screen — where the callout has to clamp above the pad
                // instead of sitting beside its note.
                honorLayoutBreaks: false,
            ),
        ])
    }

    var body: some View {
        ScreenshotSceneFrame(
            title: LocalizedStringResource(
                "scene.noteEditing.title",
                table: "ScreenshotStrings",
                bundle: .forClass(ScreenshotStringsAnchor.self),
            ),
            subtitle: LocalizedStringResource(
                "scene.noteEditing.subtitle",
                table: "ScreenshotStrings",
                bundle: .forClass(ScreenshotStringsAnchor.self),
            ),
            layout: FolinoScreenshotLayout.layout(for: idiom, subtitleBullet: true, innerStatusBarHeight: 0),
            idiom: idiom,
        ) {
            // ReaderRootScreen draws its own top strip and hides the system navigation bar, so this NavigationStack
            // contributes no chrome of its own — it's here only so `.restoresInteractivePopGesture()` has a
            // `UINavigationController` ancestor to install its edge-swipe delegate on.
            NavigationStack {
                EditableReaderScreen(
                    item: Fixture.items[0],
                    scoresDirectory: URL(filePath: NSTemporaryDirectory()),
                    gateway: FixtureGateway(),
                    repository: repository,
                    originalStore: FixtureOriginalStore(),
                    historyStore: Self.historyStore,
                    playbackController: nil,
                    // No ink store: this scene draws one framed screenshot of the editing surface and never runs a
                    // part edit, so there is no annotation layer for the part-index migration to rewrite.
                    annotationStore: nil,
                    // `startInEditMode` is unused here: this scene enters edit mode via
                    // `ReaderScreenshotEditing.requestedMeasure` instead, so it's picked up with a selected note.
                ) { host, chrome, topBar, cutoutTier, _ in
                    ReaderRootScreen(
                        scoreItem: Fixture.items[0],
                        repository: repository,
                        originalStore: FixtureOriginalStore(),
                        gateway: FixtureGateway(),
                        shareService: FixtureShareService(),
                        vocalTunerHandoff: NoopVocalTunerHandoff(),
                        metadataReader: FixtureMetadataReader(),
                        annotationCoordinator: .fixture,
                        scoresDirectory: URL(filePath: NSTemporaryDirectory()),
                        editingHost: host,
                        editingChrome: chrome,
                        editingTopBar: topBar,
                        editingCutoutTier: cutoutTier,
                    )
                }
            }
            .readerStatusBarBand(for: idiom)
        } overlay: {
            EmptyView()
        }
    }
}

#Preview("iPhone", traits: .appStoreIPhone) {
    NoteEditingScene().environment(\.screenshotIdiom, .iPhone)
}

#Preview("iPad", traits: .appStoreIPad) {
    NoteEditingScene().environment(\.screenshotIdiom, .iPad)
}
