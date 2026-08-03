import Domain
@testable import Reader
import ScreenshotKit
import SheetMusicCore
import SheetMusicLayout
import SheetMusicUI
import SwiftUI
import UtilityUI

/// Marker class used to resolve the bundle that hosts `ScreenshotStrings.xcstrings`. See `LibraryScene` for the
/// rationale behind `.forClass` over `.atURL(Bundle.main.bundleURL)`.
private final class ScreenshotStringsAnchor {}

/// A static marketing mock of Folino's Picture-in-Picture playback: an iOS-home-screen-like surface with a floating
/// white PiP window showing the score + a blue playback cursor.
///
/// This is *not* the real `AVPictureInPicture` / `ReaderPiPSession` pipeline (that needs a live PiP session and a
/// `CVPixelBuffer` feed). Instead it composes the home-screen layout from primitives (colored rounded-square "icons",
/// a search pill, a dock) and renders the score directly with `SheetMusicUI.ScoreView` in single-system horizontal mode
/// (`wrapToViewWidth: false`) — which lays out synchronously, so it renders in `#Preview` without an async settle pass.
/// A `.beat` `ScoreCursor` drives the blue cursor that `ScoreView`'s `PlaybackCursorView` paints, mimicking the live
/// PiP window.
struct PiPScene: View {
    @Environment(\.screenshotIdiom) private var idiom

    init() {
        // Font provider + hint suppression — also here (not only in ScreenshotApp.init) so #Preview renders notation.
        ScreenshotSetup.ensure()
    }

    /// The one scene that stays on `ScreenshotFrameView` rather than `ScreenshotSceneFrame`: `TrueScaleInner` exists so
    /// that *real app UI* — whose fonts, controls and paddings are fixed points — is laid out at the device's size
    /// instead of the thumbnail's. `HomeScreenMock` is a drawing, not app UI: every dimension in it is a fraction of
    /// the slot it's given, so laying it out larger and scaling the raster back down would be a no-op — except for
    /// `PiPScoreView`'s absolute `staffSize`, which was tuned against this slot and would come out ~20% small.
    var body: some View {
        ScreenshotFrameView(
            title: LocalizedStringResource(
                "scene.pip.title",
                table: "ScreenshotStrings",
                bundle: .forClass(ScreenshotStringsAnchor.self),
            ),
            subtitle: LocalizedStringResource(
                "scene.pip.subtitle",
                table: "ScreenshotStrings",
                bundle: .forClass(ScreenshotStringsAnchor.self),
            ),
            // No inner status-bar band: HomeScreenMock owns the full thumbnail and draws its own faux 9:41 row at the
            // very top. (`innerStatusBarColor` is irrelevant at height 0, but kept matching the wallpaper for safety.)
            layout: FolinoScreenshotLayout.layout(
                for: idiom,
                innerStatusBarColor: HomeScreenMock.wallpaperTopColor,
                innerStatusBarHeight: 0,
            ),
        ) {
            HomeScreenMock()
        } overlay: {
            EmptyView()
        }
    }
}

/// The home-screen surface: an abstract gradient "wallpaper" (no image), a faux status-bar row, a grid of colored
/// rounded-square icons (no labels; 4 columns on iPhone, 5 on iPad), and a floating PiP score window overlapping the
/// top of the grid. iPhone additionally shows a search pill and a bottom dock; iPad omits both.
private struct HomeScreenMock: View {
    /// Top color of the abstract wallpaper gradient. Exposed so the framed status-bar band can match it.
    static let wallpaperTopColor = Color(.sRGB, red: 0.20, green: 0.24, blue: 0.40)
    private static let wallpaperBottomColor = Color(.sRGB, red: 0.3, green: 0.5, blue: 0.72)

    /// Tasteful icon palette — arbitrary colors standing in for app icons (no labels, no real glyphs).
    private static let palette: [Color] = [
        Color(.sRGB, red: 0.95, green: 0.42, blue: 0.42), // coral
        Color(.sRGB, red: 0.98, green: 0.71, blue: 0.30), // amber
        Color(.sRGB, red: 0.40, green: 0.78, blue: 0.55), // green
        Color(.sRGB, red: 0.35, green: 0.62, blue: 0.95), // blue
        Color(.sRGB, red: 0.66, green: 0.50, blue: 0.92), // violet
        Color(.sRGB, red: 0.95, green: 0.55, blue: 0.78), // pink
        Color(.sRGB, red: 0.30, green: 0.78, blue: 0.82), // teal
        Color(.sRGB, red: 0.98, green: 0.84, blue: 0.36), // yellow
    ]

    @Environment(\.screenshotIdiom) private var idiom

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                // Abstract wallpaper — gradient only, no image.
                LinearGradient(
                    colors: [Self.wallpaperTopColor, Self.wallpaperBottomColor],
                    startPoint: .top,
                    endPoint: .bottom,
                )

                homeStack(
                    size: geo.size,
                    iconSide: geo.size.width * (idiom == .iPad ? 0.09 : 0.16),
                    rows: 4,
                    cols: idiom == .iPad ? 5 : 4,
                )

                // Faux Dynamic Island — black pill centered at the top, sized/positioned to match a real iPhone
                // (≈125/393 wide, ≈37/852 tall, ≈11/852 from the top), between the time and the status icons.
                if idiom == .iPhone {
                    Capsule(style: .continuous)
                        .fill(.black)
                        .frame(width: geo.size.width * 0.32, height: geo.size.height * 0.043)
                        .padding(.top, geo.size.height * 0.013)
                }

                // Floating PiP window — overlaps the top of the icon grid, leaving the status bar + first icon row
                // visible above it so the home-screen surface reads clearly behind the floating window.
                pipWindow(width: geo.size.width)
                    .padding(.top, geo.size.height * (idiom == .iPad ? 0.03 : 0.085))
            }
        }
    }

    // MARK: - Home-screen stack (status bar + grid + search + dock)

    private func homeStack(
        size: CGSize,
        iconSide: CGFloat, rows: Int, cols: Int,
    ) -> some View {
        VStack(spacing: 0) {
            statusBar(width: size.width)
                // iPhone: vertically centered on the Dynamic Island. iPad: no Dynamic Island, so push the row right up
                // to the thumbnail's top edge (the inner status-bar band is disabled, innerStatusBarHeight: 0, so this
                // row owns the very top).
                    .padding(.top, size.height * (idiom == .iPad ? 0.006 : 0.026))

            Spacer().frame(height: size.height * (idiom == .iPad ? 0.1 : 0.03))

            iconGrid(
                rows: rows,
                cols: cols,
                iconSide: iconSide,
                horizontalSpacing: size.width * (idiom == .iPad ? 0.058 : 0.07),
                verticalSpacing: size.height * (idiom == .iPad ? 0.0725 : 0.0465),
            )

            Spacer(minLength: 0)

            if idiom == .iPhone {
                searchPill(width: size.width)
                    .padding(.bottom, size.height * 0.028)

                dock(iconSide: iconSide, gap: size.width * 0.06)
                    // Only a small margin below the dock (sits near the very bottom of the home screen).
                        .padding(.bottom, size.height * 0.019)
            }
        }
    }

    // MARK: - Status bar (faux)

    private func statusBar(width: CGFloat) -> some View {
        HStack {
            Text("9:41")
                .font(.system(size: width * (idiom == .iPad ? 0.021 : 0.04), weight: .semibold))
                .foregroundStyle(.white)
            Spacer()
            HStack(spacing: width * 0.012) {
                if idiom == .iPhone {
                    Image(systemName: "cellularbars")
                }
                Image(systemName: "wifi")
                Image(systemName: "battery.100percent")
            }
            .font(.system(size: width * (idiom == .iPad ? 0.018 : 0.038), weight: .semibold))
            .foregroundStyle(.white)
        }
        .padding(.leading, width * (idiom == .iPad ? 0.021 : 0.13))
        .padding(.trailing, width * (idiom == .iPad ? 0.02 : 0.09))
    }

    // MARK: - Icon grid

    private func iconGrid(
        rows: Int,
        cols: Int,
        iconSide: CGFloat,
        horizontalSpacing: CGFloat,
        verticalSpacing: CGFloat,
    ) -> some View {
        VStack(spacing: verticalSpacing) {
            ForEach(0 ..< rows, id: \.self) { row in
                HStack(spacing: horizontalSpacing) {
                    ForEach(0 ..< cols, id: \.self) { col in
                        icon(
                            color: Self.palette[(row * cols + col) % Self.palette.count],
                            side: iconSide,
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func icon(color: Color, side: CGFloat) -> some View {
        let radius = side * 0.26
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [color, color.opacity(0.78)],
                    startPoint: .top,
                    endPoint: .bottom,
                ),
            )
            .regularGlassCompat(in: .rect(cornerRadius: radius))
            .frame(width: side, height: side)
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.5),
            )
    }

    // MARK: - Search pill

    private func searchPill(width: CGFloat) -> some View {
        Color.clear
            .frame(width: width * 0.16, height: width * 0.06)
            .clearGlassMock(in: .capsule)
    }

    // MARK: - Dock

    /// Dock: the same icon size as the grid, inset by `innerPad` inside a rounded glass container.
    private func dock(iconSide: CGFloat, gap: CGFloat) -> some View {
        let innerPad = iconSide * 0.3
        return HStack(spacing: gap) {
            ForEach(0 ..< 4, id: \.self) { i in
                icon(
                    color: Self.palette[(i * 2 + 1) % Self.palette.count],
                    side: iconSide,
                )
            }
        }
        .padding(innerPad)
        .clearGlassMock(in: .rect(cornerRadius: (iconSide + innerPad * 2) * 0.32))
    }

    // MARK: - PiP window

    private func pipWindow(width: CGFloat) -> some View {
        // Floating PiP window sized to fit the 3 visible staves. iPhone: full content width, centered. iPad: narrower
        // (0.67×) and trailing-aligned, matching the real iPad PiP window's resting position.
        let sideMargin = width * 0.03
        let maxWidth = width - sideMargin * 2
        let windowWidth = maxWidth * (idiom == .iPad ? 0.67 : 1)
        let windowHeight = windowWidth * (idiom == .iPad ? 0.5 : 0.4)
        let radius = windowWidth * 0.07 // Clearly rounded iOS PiP window.
        return RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color.white)
            .frame(width: windowWidth, height: windowHeight)
            .overlay {
                GeometryReader { geometry in
                    PiPScoreView(idiom: idiom)
                        .frame(width: geometry.size.width, alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                }
            }
            .shadow(color: .black.opacity(0.2), radius: 18, x: 0, y: 10)
            .frame(width: maxWidth, alignment: .trailing)
    }
}

/// The score rendered inside the PiP window. Uses `SheetMusicUI.ScoreView` in single-system horizontal mode
/// (`wrapToViewWidth: false`), which lays out synchronously — so the staff renders in `#Preview` without the async
/// settle pass that the full Reader containers need. A `.beat` cursor parks the blue playback line a few beats in,
/// mimicking the live PiP window. The wide single system is left-clipped by the enclosing window so a few measures
/// stay visible.
private struct PiPScoreView: View {
    let idiom: ScreenshotIdiom

    private var options: ScoreViewOptions {
        ScoreViewOptions(
            staffSize: idiom == .iPad ? 21 : 11,
            systemGap: 13,
            wrapToViewWidth: false,
            includeTitleFrame: false,
            breakPolicy: .ignoreAll,
            breakIndicatorVisibility: .none,
        )
    }

    /// The fixture score reduced to only its 2nd/3rd/4th staves (flat indices 1, 2, 3 — Top / 2nd / 3rd), mimicking
    /// the reference PiP window. `filtered(hidingStaves:)` is keyed by `StaffAddress(partIndex, staffIndexInPart)` on
    /// the pre-filter score, so we walk every part's staves in order, assign each a flat index, and hide all but
    /// 1, 2, 3. Parts left with no surviving staff are dropped by `filtered`, so the result is exactly Top/2nd/3rd.
    private static let visibleScore: Score = {
        let full = Fixture.score
        let keepFlatIndices: Set = [1, 2, 3]
        var hidden: Set<StaffAddress> = []
        var flat = 0
        for (partIndex, part) in full.parts.enumerated() {
            for staffIndex in part.staves.indices {
                if !keepFlatIndices.contains(flat) {
                    hidden.insert(StaffAddress(partIndex: partIndex, staffIndexInPart: staffIndex))
                }
                flat += 1
            }
        }
        return full.filtered(hidingStaves: hidden)
    }()

    var body: some View {
        ScoreView(
            score: Self.visibleScore,
            options: options,
            // Park the cursor a couple of measures in so the blue line sits inside the visible window.
            playbackCursor: .beat(measureIndex: 1, tickInMeasure: 0),
            playbackCursorColor: Color(.sRGB, red: 0.16, green: 0.45, blue: 0.96),
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
    }
}

extension View {
    /// `.glassEffect(.clear, in:)` on iOS 26+, a thin material below it.
    ///
    /// Local to this scene rather than a `UtilityUI` compat helper: the home-screen mock is the only thing in the app
    /// that wants *clear* glass, and capture always runs on an iOS 26+ simulator, so the fallback exists only to keep
    /// the file compiling at the app's iOS 18 floor.
    @ViewBuilder
    fileprivate func clearGlassMock(in shape: some Shape) -> some View {
        if #available(iOS 26, *) {
            glassEffect(.clear, in: shape)
        } else {
            background(.thinMaterial, in: shape)
        }
    }
}

#Preview("iPhone", traits: .appStoreIPhone) {
    PiPScene().environment(\.screenshotIdiom, .iPhone)
}

#Preview("iPad", traits: .appStoreIPad) {
    PiPScene().environment(\.screenshotIdiom, .iPad)
}
