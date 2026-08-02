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

/// A control a hint can be anchored to. Reported in GLOBAL coordinates rather than through
/// `anchorPreference`: the toolbar's items are hosted by the navigation bar in a separate hosting controller, so
/// SwiftUI preferences never reach the Reader's own view tree — but the window they share does give both sides one
/// coordinate space.
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
