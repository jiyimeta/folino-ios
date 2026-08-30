import Foundation

/// A Reader affordance that is icon-only or gesture-only, and therefore hard to discover by looking at it. Each hint
/// retires permanently once its own feature has actually been used.
///
/// Ported from synclick's `FeatureHint` (same one-slot, round-robin, retire-on-use model), with two differences. The
/// Reader's hints point at controls that only exist in some states (a PDF has no note-editing button), so selection
/// also filters on what is on screen right now. And one hint sits OUTSIDE the rotation and its one-per-launch budget,
/// because it fires at the moment the user has walked into the thing it explains: `transportExpand`, whenever the
/// transport is compact (see `ReaderHintCoordinator`).
enum ReaderFeatureHint: String, CaseIterable {
    /// Swipe the expanded transport right to shrink it to the compact pill. In the rotation.
    case transportCollapse
    /// Swipe the compact transport left to bring the seek card back.
    ///
    /// Not in the rotation and not budgeted: shown every time the transport is compact and this has not been used yet.
    /// A compact pill gives no hint that anything larger exists, and the moment it matters most is right after the
    /// user has just shrunk it — which is exactly when a once-per-launch budget would already be spent.
    case transportExpand
    /// The note-editing entry point (`music.quarternote.3`).
    ///
    /// The raw value is deliberately not `noteEditing`: it is the persistence key
    /// (`readerHint.used.<rawValue>`), so changing it retires the OLD record and offers this hint again to everyone
    /// who had already dismissed it. The glyph moved from `square.and.pencil` — the compose icon iOS uses for a new
    /// document — to the notes this button actually writes, and someone who learned the old one deserves to be
    /// introduced to the new one rather than to find their button replaced.
    case noteEditing = "noteEditing.quarternote"
    /// The ink-annotation toggle (`pencil.tip.crop.circle`).
    case annotation
    /// Per-part show/hide — lives in the display inspector.
    case staffVisibility
    /// Metronome on/off — lives in the playback inspector.
    case metronome
    /// Repeat / A–B loop — lives in the playback inspector.
    case repeatPlayback
    /// Per-part volume, mute and solo — lives in the playback inspector.
    case mixer
    /// The note-input pad tucks past a side edge with a sideways swipe — the gesture that replaced the old top-bar
    /// show / hide toggle. Offered on entering edit mode (see `offerPadHideHint`), outside the rotation, because
    /// the moment the pad is in the way is the moment this matters. First step of the pad chain: tucking it offers
    /// `padRestore`, restoring offers `padMove` — the transport pair's teach-by-consequence shape, one longer.
    case padHide
    /// The tab a tucked pad leaves brings it back — tap it or pull it out. Offered off the tab's appearance (the
    /// consequence of the tuck `padHide` just taught), the way `transportExpand` rides the compact pill's.
    case padRestore
    /// The note-input pad re-docks top / bottom with a vertical drag. Offered after a restore — and never if the
    /// user has already moved it on their own.
    case padMove

    /// Round-robin order. Every hint here is equal: surfaced until its own feature is used, then retired. The transport
    /// swipe leads because it is the one affordance with no icon at all — nothing on screen suggests it exists.
    static let rotationOrder: [ReaderFeatureHint] = [
        .transportCollapse,
        .noteEditing,
        .annotation,
        .staffVisibility,
        .metronome,
        .repeatPlayback,
        .mixer,
    ]

    /// The on-screen control this hint points at. Several hints share one target — the three playback-inspector hints
    /// all point at the same button, and only one of them is ever on screen at a time.
    var target: ReaderHintTarget {
        switch self {
        case .transportCollapse: .transportExpanded
        case .transportExpand: .transportCompact
        case .noteEditing: .noteEditingButton
        case .annotation: .annotationButton
        case .staffVisibility: .visualInspectorButton
        case .metronome, .repeatPlayback, .mixer: .playbackInspectorButton
        case .padHide, .padMove: .noteInputPad
        case .padRestore: .noteInputPadHandle
        }
    }
}

/// A control a hint can be anchored to. Reported in WINDOW coordinates rather than through `anchorPreference` —
/// window frames are what `onWindowFrameChange` hands out, and they survive being read across hosting contexts where
/// SwiftUI's `.global` space does not.
///
/// The transport is two targets rather than one because each of its two states teaches a different swipe, and the
/// state a hint's copy describes has to be the state the user is looking at. Only one of the two is ever anchored.
enum ReaderHintTarget: String, Hashable {
    case transportExpanded
    case transportCompact
    case noteEditingButton
    case annotationButton
    case visualInspectorButton
    case playbackInspectorButton
    /// The note-input pad itself. Its frame is relayed through `ReaderEditingHost.noteInputPadFrame` — the pad is
    /// App-injected Editor code, so a `readerHintAnchor` this feature attaches itself never sees it.
    case noteInputPad
    /// The pull tab a tucked pad leaves at the screen edge — relayed the same way
    /// (`ReaderEditingHost.noteInputPadHandleFrame`).
    case noteInputPadHandle

    /// Where the bubble sits relative to its anchor. Fixed chrome answers statically: top-of-screen controls drop
    /// below (caret up), the bottom-docked transport floats above (caret down). The pad and its tab are the targets
    /// that can rest at either edge, so they answer by where their anchor actually is.
    func placement(anchorMidY: CGFloat = 0, viewportHeight: CGFloat = .infinity) -> ReaderHintPlacement {
        switch self {
        case .transportExpanded, .transportCompact:
            .above
        case .noteEditingButton, .annotationButton, .visualInspectorButton, .playbackInspectorButton:
            .below
        case .noteInputPad, .noteInputPadHandle:
            anchorMidY < viewportHeight / 2 ? .below : .above
        }
    }
}

enum ReaderHintPlacement {
    case above
    case below
}
