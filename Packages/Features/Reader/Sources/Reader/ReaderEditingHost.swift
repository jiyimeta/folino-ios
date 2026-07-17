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
    /// Written by the App (mirroring `EditorViewModel.hoverItem(at:)`), read by the Reader: the item under an Apple
    /// Pencil hover, drawn as a soft pre-highlight by the editing overlay. `nil` when nothing is hovered.
    public var hoverItem: SheetMusicCore.ScoreItemID?

    /// Written by the Reader, read by the App/Editor:
    /// Latest LayoutDocument of the editing surface (published by VerticalScoreContainer).
    public internal(set) var document: LayoutDocument?
    /// Screen-space (global) frame of the current selection anchor, for positioning the iPhone callout.
    public internal(set) var selectionScreenFrame: CGRect?

    // App-wired callbacks:
    public var onBeginEditing: @MainActor (Score) -> Void = { _ in }
    public var onEndEditing: @MainActor () -> Void = {}
    public var onTap: @MainActor (CGPoint) -> Void = { _ in }
    /// Staff-step drag commit from the pitch-drag handle; positive steps = up.
    public var onPitchDragCommit: @MainActor (Int) -> Void = { _ in }
    /// Apple Pencil hover position (score-surface coordinates), or `nil` when the hover ends. `nil` by default so
    /// the Reader's `.onContinuousHover` is a no-op until the App wires it up.
    public var onHover: (@MainActor (CGPoint?) -> Void)?

    /// The editing chrome's 完了 requests exit through here (the chrome is App-injected and cannot call Reader code).
    public private(set) var isExitRequested = false
    public func requestExit() {
        isExitRequested = true
    }

    func resetExitRequest() {
        isExitRequested = false
    }
}

/// Context handed to the App's chrome builder each body pass.
public struct ReaderEditingChromeContext {
    public let selectionScreenFrame: CGRect?
}
