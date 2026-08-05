import Foundation

/// A Reader affordance that is icon-only or gesture-only, and therefore hard to discover by looking at it. Each hint
/// retires permanently once its own feature has actually been used.
///
/// Ported from synclick's `FeatureHint` (same one-slot, round-robin, retire-on-use model), with two differences. The
/// Reader's hints point at controls that only exist in some states (a PDF has no note-editing button), so selection
/// also filters on what is on screen right now. And two hints sit OUTSIDE the rotation and its one-per-launch budget,
/// because both fire at the moment the user has walked into the thing they explain: `notePad` on entering edit mode,
/// and `transportExpand` whenever the transport is compact (see `ReaderHintCoordinator`).
enum ReaderFeatureHint: String, CaseIterable {
    /// Swipe the expanded transport right to shrink it to the compact pill. In the rotation.
    case transportCollapse
    /// Swipe the compact transport left to bring the seek card back.
    ///
    /// Not in the rotation and not budgeted: shown every time the transport is compact and this has not been used yet.
    /// A compact pill gives no hint that anything larger exists, and the moment it matters most is right after the
    /// user has just shrunk it — which is exactly when a once-per-launch budget would already be spent.
    case transportExpand
    /// The note-editing entry point (`square.and.pencil`).
    case noteEditing
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
    /// The note-input pad. Offered on entering edit mode, because a pad you don't know about is the one thing that
    /// makes edit mode look like it does nothing. Points at the pad's open/close button rather than the pad, since the
    /// pad starts hidden (`editorPadVisible` defaults to `false`).
    case notePad

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
        case .notePad: .noteInputToggle
        }
    }
}

/// A control a hint can be anchored to. Reported in WINDOW coordinates rather than through `anchorPreference`: the
/// toolbar's items are hosted by the navigation bar in a separate hosting controller, so SwiftUI preferences never
/// reach the Reader's own view tree — and neither does SwiftUI's `.global`, which is resolved per hosting context.
/// The window is the one coordinate space both sides genuinely share (`onWindowFrameChange`).
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
    /// The editing chrome's pad open/close button. Lives in App-injected Editor code, so its frame is relayed through
    /// `ReaderEditingHost.noteInputAnchorFrame` instead of a `readerHintAnchor` the Reader attaches itself.
    case noteInputToggle

    /// Where this control sits among the navigation bar's items, or `nil` for the ones the Reader draws itself.
    ///
    /// A bar-hosted control cannot report its own position (see `ReaderBarItemLocator`), so it declares its PLACE in
    /// the bar instead and is matched to a measured item by counting. `order` is the control's position in the
    /// sequence its screen states — the Reader's own trailing sequence for the toolbar, the editing chrome's leading
    /// sequence for the pad toggle — and gaps are fine: what matters is the relative order of the items that are
    /// actually on screen, which is what the counting uses.
    var barSlot: ReaderBarSlot? {
        switch self {
        // `ReaderToolbar`'s trailing sequence: score info (0), share (1), then these.
        case .noteEditingButton: .trailing(order: 2)
        case .annotationButton: .trailing(order: 3)
        case .playbackInspectorButton: .trailing(order: 4)
        case .visualInspectorButton: .trailing(order: 5)
        // The pad toggle is drawn by App-injected Editor code, which is the only side that knows where it sits in the
        // editing chrome's own leading sequence — so its slot arrives through the seam
        // (`ReaderEditingHost.noteInputBarLeadingOrder`) rather than being stated here.
        case .noteInputToggle: nil
        case .transportExpanded, .transportCompact: nil
        }
    }

    /// Where the bubble sits relative to its anchor. Top-of-screen controls drop below (caret up); the bottom-docked
    /// transport floats above (caret down).
    var placement: ReaderHintPlacement {
        switch self {
        case .transportExpanded, .transportCompact:
            .above
        case .noteEditingButton, .annotationButton, .visualInspectorButton, .playbackInspectorButton, .noteInputToggle:
            .below
        }
    }
}

enum ReaderHintPlacement {
    case above
    case below
}

/// Which end of the navigation bar a hinted control is pinned to, and how far along it sits.
///
/// Counting is done from the control's OWN end — trailing items from the right, leading items from the left — because
/// that is the end whose ordering survives: iOS folds a crowded bar from the inside out, so an item's distance from
/// the edge it is pinned to stays put while the middle collapses.
enum ReaderBarSlot: Equatable {
    case leading(order: Int)
    case trailing(order: Int)
}
