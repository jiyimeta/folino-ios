import Foundation

/// A Reader affordance that is icon-only or gesture-only, and therefore hard to discover by looking at it. Each hint
/// retires permanently once its own feature has actually been used.
///
/// Ported from synclick's `FeatureHint` (same one-slot, round-robin, retire-on-use model), with two differences. The
/// Reader's hints point at controls that only exist in some states (a PDF has no note-editing button), so selection
/// also filters on what is on screen right now. And one hint sits OUTSIDE the rotation and its one-per-launch budget,
/// because it fires at the moment the user has walked into the thing it explains: `transportExpand`, whenever the
/// transport is compact (see `ReaderHintEngine`).
///
/// Platform-neutral: the cases, the rotation order, the target mapping and the persistence key format are what make
/// the two platforms' coach marks the *same* feature rather than two that resemble each other. Only the bubble's
/// drawing and the anchor plumbing are per-platform.
public enum ReaderFeatureHint: String, CaseIterable, Sendable {
    /// Swipe the expanded transport right to shrink it to the compact pill. In the rotation.
    case transportCollapse
    /// Swipe the compact transport left to bring the seek card back.
    ///
    /// Not in the rotation and not budgeted: shown every time the transport is compact and this has not been used yet.
    /// A compact pill gives no hint that anything larger exists, and the moment it matters most is right after the
    /// user has just shrunk it — which is exactly when a once-per-launch budget would already be spent.
    case transportExpand
    /// The note-editing entry point — three quarter notes on both platforms now (`music.quarternote.3` on iOS, the
    /// `ic_music_note_3` drawable on Android).
    ///
    /// The raw value is deliberately not `noteEditing`: it is the persistence key
    /// (`readerHint.used.<rawValue>`), so changing it retires the OLD record and offers this hint again to everyone
    /// who had already dismissed it. Both glyphs moved off a pencil — iOS from `square.and.pencil`, the compose icon
    /// the platform uses for a NEW document, and Android from `EditNote`, a pencil over ruled paper — to the notes
    /// this button actually writes. Someone who learned the old one deserves an introduction rather than a silently
    /// swapped button, and now that is true on both.
    case noteEditing = "noteEditing.quarternote"
    /// The ink-annotation toggle (`pencil.tip.crop.circle` on iOS, `Draw` on Android).
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
    /// show / hide toggle. Offered on entering edit mode (see `offerPadGestureHint`), outside the rotation, because
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
    public static let rotationOrder: [ReaderFeatureHint] = [
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
    public var target: ReaderHintTarget {
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

    /// The key this hint's "already used" flag is stored under. One format, both platforms — the screenshot harness
    /// retires every hint by writing these directly, and Android's own store has to spell them the same way or a
    /// user who has dismissed a hint would meet it again after a reinstall of the other platform's build.
    public var usedKey: String {
        "readerHint.used.\(rawValue)"
    }

    /// Stable number for the JNI boundary. Declared rather than derived from `allCases` so reordering the cases (or
    /// inserting one) can never silently renumber what is already on the wire.
    public var wireValue: Int32 {
        switch self {
        case .transportCollapse: 0
        case .transportExpand: 1
        case .noteEditing: 2
        case .annotation: 3
        case .staffVisibility: 4
        case .metronome: 5
        case .repeatPlayback: 6
        case .mixer: 7
        case .padHide: 8
        case .padRestore: 9
        case .padMove: 10
        }
    }

    /// The `wireValue` inverse. `nil` for the "nothing is showing" sentinel and for anything unrecognized, so an
    /// Android build running against an older library degrades to "no hint" rather than trapping.
    public static func fromWireValue(_ value: Int32) -> ReaderFeatureHint? {
        allCases.first { $0.wireValue == value }
    }

    /// What an empty hint slot is on the wire. A struct field cannot be optional across the bridge, so "nothing
    /// showing" travels as a number no hint claims.
    public static let noHintWireValue: Int32 = -1
}

/// A control a hint can be anchored to. Reported in WINDOW coordinates rather than through SwiftUI's
/// `anchorPreference` (or Compose's local coordinates) — window frames survive being read across the hosting
/// contexts where a view-relative space does not.
///
/// The transport is two targets rather than one because each of its two states teaches a different swipe, and the
/// state a hint's copy describes has to be the state the user is looking at. Only one of the two is ever anchored.
public enum ReaderHintTarget: String, Hashable, CaseIterable, Sendable {
    case transportExpanded
    case transportCompact
    case noteEditingButton
    case annotationButton
    case visualInspectorButton
    case playbackInspectorButton
    /// The note-input pad itself. On iOS its frame is relayed through `ReaderEditingHost.noteInputPadFrame` — the pad
    /// is App-injected Editor code, so an anchor modifier the Reader feature attaches itself never sees it.
    case noteInputPad
    /// The pull tab a tucked pad leaves at the screen edge — relayed the same way.
    case noteInputPadHandle

    /// Where the bubble sits relative to its anchor. Fixed chrome answers statically: top-of-screen controls drop
    /// below (caret up), the bottom-docked transport floats above (caret down). The pad and its tab are the targets
    /// that can rest at either edge, so they answer by where their anchor actually is.
    public func placement(anchorMidY: Double = 0, viewportHeight: Double = .infinity) -> ReaderHintPlacement {
        switch self {
        case .transportExpanded, .transportCompact:
            .above
        case .noteEditingButton, .annotationButton, .visualInspectorButton, .playbackInspectorButton:
            .below
        case .noteInputPad, .noteInputPadHandle:
            anchorMidY < viewportHeight / 2 ? .below : .above
        }
    }

    /// Stable number for the JNI boundary — see `ReaderFeatureHint.wireValue`.
    public var wireValue: Int32 {
        switch self {
        case .transportExpanded: 0
        case .transportCompact: 1
        case .noteEditingButton: 2
        case .annotationButton: 3
        case .visualInspectorButton: 4
        case .playbackInspectorButton: 5
        case .noteInputPad: 6
        case .noteInputPadHandle: 7
        }
    }

    public static func fromWireValue(_ value: Int32) -> ReaderHintTarget? {
        allCases.first { $0.wireValue == value }
    }
}

public enum ReaderHintPlacement: Int32, Sendable {
    case above = 0
    case below = 1
}
