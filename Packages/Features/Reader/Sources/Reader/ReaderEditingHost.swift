import Observation
import SheetMusicCore
import SheetMusicLayout
import SheetMusicUI
import SwiftUI

/// Injection seam for the note-editing feature (design spec §9, Option 1). The Reader owns edit-mode lifecycle and
/// score presentation; the App composition root connects this host to the Editor feature's view model. The Reader
/// never sees Editor types and vice versa.
@MainActor
@Observable
public final class ReaderEditingHost {
    public init() {}

    /// True while edit mode is active. Set by the Reader (entry button / exit).
    public internal(set) var isEditing = false

    /// Written by the App (mirroring EditorViewModel outputs), read by the Reader:
    /// The editor's live score. While editing the Reader renders THIS raw score (no transpose / hidden staves /
    /// multi-measure-rest collapse) so positional IDs stay valid.
    public var editedScore: Score?
    /// Bumped per mutation; included in the vertical container's layout task key.
    public var editGeneration = 0
    public var selection: ScoreSelection = .none
    /// The caret target (insertion indicator drawn by the Reader's editing overlay).
    public var caretItem: SheetMusicCore.ScoreItemID?

    /// Written by the Reader, read by the App/Editor:
    /// Latest LayoutDocument of the editing surface (published by the score container).
    public internal(set) var document: LayoutDocument?
    /// Whether the transport is currently playing. Editing and playback coexist — you can audition the passage you
    /// are working on without leaving edit mode — but every key that would mutate the score has to go inert while
    /// the cursor is running, since an edit mid-playback would reflow the score out from under it.
    public internal(set) var isPlaying = false

    /// Written by the App (measured from the editing chrome), read by the Reader: how much vertical room the editing
    /// cluster occupies at the top and bottom of the screen. The score containers turn these into SCROLL PADDING, not
    /// layout width — so the last system can be scrolled clear of the pad without the score being re-engraved. Page
    /// mode deliberately ignores them: its bottom reserve feeds `LayoutPaginator`, so honoring them there would move
    /// the page breaks the moment you started editing.
    public var editingChromeTopInset: CGFloat = 0
    public var editingChromeBottomInset: CGFloat = 0

    // App-wired callbacks:
    public var onBeginEditing: @MainActor (Score) -> Void = { _ in }
    public var onEndEditing: @MainActor () -> Void = {}
    public var onTap: @MainActor (CGPoint) -> Void = { _ in }

    /// The editing chrome's 完了 requests exit through here (the chrome is App-injected and cannot call Reader code).
    public private(set) var isExitRequested = false
    public func requestExit() {
        isExitRequested = true
    }

    func resetExitRequest() {
        isExitRequested = false
    }
}

/// Presentation constants every score surface shares while editing, so vertical / horizontal / paged all tint the
/// selection identically.
enum ReaderEditingPresentation {
    /// `SelectionRenderState.color(for:voiceIndex:)` only tints items present in `ScoreSelection`, so a flat
    /// accent-color map for every voice index is safe — non-selected items render unaffected regardless of voice.
    static let voiceColors: [Int: Color] = [
        0: .accentColor, 1: .accentColor, 2: .accentColor, 3: .accentColor,
    ]
}

/// Context handed to the App's chrome builder each body pass.
public struct ReaderEditingChromeContext {
    /// Room the reader's own transport occupies at the bottom of the screen, so a bottom-docked pad can sit clear of
    /// it. The transport stays anchored to the bottom edge and stays the Reader's to draw; only the pad moves.
    public let bottomTransportClearance: CGFloat

    public init(bottomTransportClearance: CGFloat) {
        self.bottomTransportClearance = bottomTransportClearance
    }
}
