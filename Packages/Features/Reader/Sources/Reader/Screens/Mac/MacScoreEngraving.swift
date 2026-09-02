#if os(macOS)
import Domain
import PencilKit
import SheetMusicCore
import SheetMusicLayout
import SheetMusicUI
import SwiftUI

/// The one place the Mac reader decides what a score's engraving IS: the options it is laid out with, the identity
/// that decides when it must be laid out again, and the projection of stored ink into it.
///
/// **Why this exists as one type rather than three copies.** All three Mac containers — vertical, page and
/// horizontal — engrave the same score from the same six preferences, and each grew its own `scoreOptions`, its own
/// layout key re-deriving the same `scoreSignature`, and its own copy of the ink projection. That was invisible
/// until sub-project Ⅳ adds Reader preferences: one new `ScoreViewOptions` field would then mean editing three
/// option builders and three keys, and missing one gives a stale engraving in exactly one display mode — a bug that
/// only appears after switching modes, which is the last place anyone looks.
///
/// The two things that legitimately differ between the modes are parameters here, not forks: horizontal lays out at
/// natural width with no title frame, and only vertical's layout depends on the window's width.
enum MacScoreEngraving {
    /// The Reader's engraving options for one display mode.
    ///
    /// `wrapToViewWidth` / `includeTitleFrame` are the whole of the difference between the modes: vertical and page
    /// both wrap to a width and want the title, horizontal lays the score out as one long row where a title frame
    /// would only push the staves down. Everything else is the same six preferences in the same shape as the iOS
    /// containers, which is what makes a mode the same mode on both platforms.
    static func options(
        staffSize: CGFloat,
        honorLayoutBreaks: Bool,
        collapseMultiMeasureRests: Bool,
        showInvisibleElements: Bool,
        showAllMeasureNumbers: Bool,
        wrapToViewWidth: Bool = true,
        includeTitleFrame: Bool = true,
    ) -> ScoreViewOptions {
        ScoreViewOptions(
            staffSize: staffSize, systemGap: staffSize * 1.25,
            wrapToViewWidth: wrapToViewWidth, includeTitleFrame: includeTitleFrame,
            breakPolicy: honorLayoutBreaks ? .honor : .ignoreAll,
            breakIndicatorVisibility: .none,
            multiMeasureRest: collapseMultiMeasureRests
                ? .collapse(minimumMeasures: ReaderPreferences.multiMeasureRestThreshold)
                : .disabled,
            showsInvisibleElements: showInvisibleElements,
            measureNumbers: showAllMeasureNumbers ? .everyMeasure : .systemStart,
        )
    }

    /// Place every stored stroke in `document`'s coordinate space.
    ///
    /// Call this from a relayout task or an annotation-layer watcher — never from a view body that a playback tick
    /// invalidates. It decodes and re-places every stroke in the score, so running it per tick (or, in the deck's
    /// case, per sheet) pays for the whole ink layer over and over. See `MacInkProjection`.
    @MainActor
    static func projectedInk(_ viewModel: ReaderViewModel, into document: LayoutDocument?) -> PKDrawing {
        guard let document else { return PKDrawing() }
        return AnnotationAnchoring.display(
            viewModel.annotationDrawings, in: document,
            // Stored anchors are in source addressing; `document` is engraved from the staff-filtered score.
            staffFilter: .current(viewModel: viewModel, editingHost: nil),
        )
    }
}

/// Identity for the `.task(id:)` that re-engraves the score, shared by all three Mac containers. Mirrors the iOS
/// containers' `TaskKey`, editing generation included.
///
/// `width` is `nil` for the modes whose layout does not depend on the window: page engraves into a fixed A4 sheet
/// and horizontal at the score's natural width, so a resize changes the magnification and nothing about the
/// engraving. Only vertical wraps to the viewport, and so passes one.
struct MacScoreLayoutKey: Hashable {
    let scoreSignature: Int
    let size: CGFloat
    let width: CGFloat?
    let honorLayoutBreaks: Bool
    let collapseMultiMeasureRests: Bool
    let showInvisibleElements: Bool
    let showAllMeasureNumbers: Bool
    let transposeSemitones: Int
    /// Which edit the score is while note editing, 0 otherwise. Comes from `ReaderEditingDisplay.version`, beside the
    /// score, never from the host directly — see that function's doc.
    let editingScoreVersion: Int

    init(
        score: Score,
        size: CGFloat,
        width: CGFloat? = nil,
        honorLayoutBreaks: Bool,
        collapseMultiMeasureRests: Bool,
        showInvisibleElements: Bool,
        showAllMeasureNumbers: Bool,
        transposeSemitones: Int,
        editingScoreVersion: Int = 0,
    ) {
        // `Score` is Equatable but not Hashable. Same cheap identity proxy the iOS containers use: structural shape
        // plus opening clefs, which is what makes a clef override re-trigger the task. The transpose is NOT folded
        // in here — it is a stored property of this key, so the synthesized `==` / `hash` already carry it, and the
        // three copies this replaced each XORed it in a second time for nothing.
        scoreSignature = score.parts.count
            ^ (score.totalStaffCount << 8)
            ^ (score.division << 16)
            ^ score.openingClefSignature
        self.size = size
        self.width = width
        self.honorLayoutBreaks = honorLayoutBreaks
        self.collapseMultiMeasureRests = collapseMultiMeasureRests
        self.showInvisibleElements = showInvisibleElements
        self.showAllMeasureNumbers = showAllMeasureNumbers
        self.transposeSemitones = transposeSemitones
        self.editingScoreVersion = editingScoreVersion
    }
}
#endif
