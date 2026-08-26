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

    /// Where the bubble sits relative to its anchor. Top-of-screen controls drop below (caret up); the bottom-docked
    /// transport floats above (caret down).
    var placement: ReaderHintPlacement {
        switch self {
        case .transportExpanded, .transportCompact:
            .above
        case .noteEditingButton, .annotationButton, .visualInspectorButton, .playbackInspectorButton:
            .below
        }
    }
}

enum ReaderHintPlacement {
    case above
    case below
}
