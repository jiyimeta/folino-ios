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
    public var selection: ScoreSelection = .none {
        didSet {
            if case .single = selection { onSelectionMade() }
        }
    }

    /// Fired when the editor lands on something — Reader-internal, wired by `ReaderRootScreen` to put the playhead
    /// away. Two marks on the same staff, one for "playback is here" and one for "you are editing this", read as one
    /// confused mark; the score can only carry one "you are here" at a time.
    var onSelectionMade: @MainActor () -> Void = {}
    /// The last item tapped on the score OUTSIDE edit mode — where the reader put the playhead by hand. Seeded into
    /// the editor when a session begins, so entering edit mode carries on from the note you were already looking at
    /// rather than starting with nothing selected and the pad inert.
    public internal(set) var pendingSelection: SheetMusicCore.ScoreItemID?

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

    /// GLOBAL frame of the chrome's note-input (pad open/close) button, or `nil` when the chrome isn't up. Written by
    /// the App from the Editor's chrome, read by the Reader's coach-mark overlay — which has to point at a control it
    /// neither draws nor can measure. Unlike `onSelectionAnchorChanged` this is a stored property rather than a
    /// callback: the button is fixed chrome, so it changes once per session instead of once per scroll frame.
    public var noteInputAnchorFrame: CGRect?

    /// Asks the editing chrome to reveal the note-input pad. Wired by the App to the Editor's view model; called when
    /// the user taps the note-input coach mark, so the bubble opens the pad it is pointing at rather than just naming
    /// it. The pad starts hidden, which is exactly why that hint exists.
    public var onRevealNoteInputPad: @MainActor () -> Void = {}

    // App-wired callbacks:
    public var onBeginEditing: @MainActor (Score) -> Void = { _ in }
    public var onEndEditing: @MainActor () -> Void = {}
    public var onTap: @MainActor (CGPoint) -> Void = { _ in }
    /// A tap on the paper outside the engraved area — below the last system, in the page margins. `onTap` can't
    /// answer for those: it is driven by a gesture on the score surface itself, whose frame stops where the engraving
    /// does, so a tap past the bottom system never reached it and the selection stuck.
    public var onTapOutsideScore: @MainActor () -> Void = {}
    /// The selected item's rect in GLOBAL (screen) coordinates, or nil when nothing is selected — what the editing
    /// chrome hangs its floating callout off.
    ///
    /// A callback rather than a stored property, deliberately. This fires on every scroll and zoom frame, and a
    /// stored `@Observable` value would be read by whichever body plumbed it through to the chrome — dragging the
    /// Reader (and its score layout) into a per-frame invalidation. Handing it straight to the Editor's view model
    /// keeps the re-render to the one leaf view that draws the callout.
    public var onSelectionAnchorChanged: @MainActor (CGRect?) -> Void = { _ in }

    /// The editing chrome's 完了 requests exit through here (the chrome is App-injected and cannot call Reader code).
    public private(set) var isExitRequested = false
    public func requestExit() {
        isExitRequested = true
    }

    func resetExitRequest() {
        isExitRequested = false
    }

    /// Records what a tap-to-seek landed on, so a later edit session can start there. `nearestCursor` always answers
    /// with an `.item`, but the `.beat` case exists (measure stepping, scrubbing) and names no element to select.
    func rememberTappedItem(_ cursor: ScoreCursor) {
        guard case let .item(id) = cursor else { return }
        pendingSelection = id
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
