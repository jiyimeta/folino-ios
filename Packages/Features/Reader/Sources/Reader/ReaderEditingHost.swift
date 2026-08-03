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

    // MARK: - Hidden staves: source ↔ display addressing

    /// The score the Editor addresses: every staff the file declares, hidden ones included. Wired by the Reader.
    ///
    /// Editing works in this "source" space so what gets written back to disk is the whole score. What is RENDERED,
    /// though, is `filtered(hidingStaves:)` — a staff the reader has hidden stays hidden while they edit, exactly as
    /// it was before they tapped 音符入力. That filter renumbers `StaffAddress`, so every ID crossing between the two
    /// has to be re-stamped: taps come back in display addressing, and the selection / caret the Reader draws arrive
    /// in source addressing. Only the staff part of an ID moves; measure / voice / element indices are untouched.
    ///
    /// The remap machinery is `swift-sheet-music`'s own (`filterStaffAddress` / `unfilterStaffAddress`) — the same
    /// pair the playback cursor already rides through this exact mismatch.
    var sourceScoreProvider: @MainActor () -> Score? = { nil }
    /// Which staves the reader has hidden, read live from the Reader's layout settings.
    var hiddenStavesProvider: @MainActor () -> Set<StaffAddress> = { [] }

    /// Source (full-score) ID → the addressing of the rendered, staff-filtered document. `nil` when the item lives on
    /// a staff that isn't currently shown — there is nothing on screen to draw it against.
    func displayItem(for id: SheetMusicCore.ScoreItemID) -> SheetMusicCore.ScoreItemID? {
        let hidden = hiddenStavesProvider()
        guard !hidden.isEmpty else { return id }
        guard let score = sourceScoreProvider(),
              let staff = score.filterStaffAddress(id.staff, hidingStaves: hidden)
        else { return nil }
        return Self.restamping(id, onto: staff)
    }

    /// Display ID (resolved against the rendered document) → source addressing, which is what the Editor mutates and
    /// saves. `nil` when the address can't be placed back in the full score.
    ///
    /// `public` because the App wires it into the Editor's hit-test path; its counterpart `displayItem(for:)` never
    /// leaves the Reader.
    public func sourceItem(for id: SheetMusicCore.ScoreItemID) -> SheetMusicCore.ScoreItemID? {
        let hidden = hiddenStavesProvider()
        guard !hidden.isEmpty else { return id }
        guard let score = sourceScoreProvider(),
              let staff = score.unfilterStaffAddress(id.staff, hidingStaves: hidden)
        else { return nil }
        return Self.restamping(id, onto: staff)
    }

    /// The selection in display addressing — what `ScoreView` and the caret overlay tint. A selection on a hidden
    /// staff collapses to `.none` rather than tinting whatever staff happens to sit at that index now.
    var displaySelection: ScoreSelection {
        guard case let .single(item) = selection else { return selection }
        guard let mapped = displayItem(for: item) else { return .none }
        return .single(mapped)
    }

    /// The caret in display addressing. See `displaySelection`.
    var displayCaretItem: SheetMusicCore.ScoreItemID? {
        guard let caretItem else { return nil }
        return displayItem(for: caretItem)
    }

    /// Rebuilds `id` on a different staff, leaving measure / voice / element indices alone. `.clef` passes through:
    /// the editor has no clef-editing UI, so a clef ID never travels this path.
    private static func restamping(
        _ id: SheetMusicCore.ScoreItemID, onto staff: StaffAddress,
    ) -> SheetMusicCore.ScoreItemID {
        switch id {
        case let .note(note):
            .note(NoteID(
                staff: staff, measureIndex: note.measureIndex, voiceIndex: note.voiceIndex,
                elementIndex: note.elementIndex, noteIndexInChord: note.noteIndexInChord,
            ))
        case let .rest(rest):
            .rest(RestID(
                staff: staff, measureIndex: rest.measureIndex, voiceIndex: rest.voiceIndex,
                elementIndex: rest.elementIndex,
            ))
        case let .tuplet(tuplet):
            .tuplet(TupletID(
                staff: staff, measureIndex: tuplet.measureIndex, voiceIndex: tuplet.voiceIndex,
                startElementIndex: tuplet.startElementIndex,
            ))
        case .clef:
            id
        }
    }

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
    ///
    /// The cursor is resolved against the rendered (staff-filtered) document, while the session it seeds runs in
    /// source addressing — so it is re-stamped on the way in, the same conversion the transport does for the engine.
    func rememberTappedItem(_ cursor: ScoreCursor) {
        guard case let .item(id) = cursor else { return }
        pendingSelection = sourceItem(for: id)
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
