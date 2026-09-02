import Foundation

/// One page's undo history for the live annotation canvas: snapshots of the whole drawing (its serialized bytes),
/// oldest first, and a cursor at the state the canvas currently shows. Undo and redo move the cursor; a fresh change
/// drops everything after it and appends.
///
/// Owned by the app rather than left to the canvas's own undo manager, for the same reason the note-editing session
/// keeps its own command stack: the history has to outlive the session. Leaving annotation mode and coming back has
/// to leave undo where it was, and PencilKit's undo manager does not survive the canvas being reseeded — which the
/// paged readers do on every exit (the live canvas is emptied while the static ink layers take over) and every page
/// turn.
///
/// Every change reaching the canvas is classified by comparing its bytes against the cursor's neighbours, rather than
/// by who caused it: the strip's own undo sets the canvas to the previous snapshot and is recognised as an undo by
/// the same rule that recognises a three-finger swipe. A change equal to the current snapshot is an echo and does
/// nothing. That makes the history self-consistent whatever drives the canvas, at the cost of one byte comparison
/// per change.
///
/// Snapshots are whole drawings, so the depth is capped (`maxDepth`); the oldest state is forgotten first.
public struct AnnotationPageHistory: Equatable, Sendable {
    /// How a change related to the history, as `record` saw it.
    public enum Outcome: Equatable, Sendable {
        /// Byte-equal to the current state — an echo of a seed or of the history's own undo / redo.
        case unchanged
        /// Byte-equal to the previous snapshot: the cursor moved back.
        case undone
        /// Byte-equal to the next snapshot: the cursor moved forward.
        case redone
        /// Something new: everything after the cursor is dropped and this is appended.
        case appended
    }

    public static let maxDepth = 50

    public private(set) var snapshots: [Data]
    public private(set) var cursor: Int

    /// A history whose only state is `current` — the drawing as it was when the page was first seen.
    public init(current: Data) {
        snapshots = [current]
        cursor = 0
    }

    public var canUndo: Bool {
        cursor > 0
    }

    public var canRedo: Bool {
        cursor < snapshots.count - 1
    }

    /// The bytes the canvas should be set to for an undo, or `nil` at the start of the history.
    public var undoTarget: Data? {
        canUndo ? snapshots[cursor - 1] : nil
    }

    /// The bytes the canvas should be set to for a redo, or `nil` at the end of the history.
    public var redoTarget: Data? {
        canRedo ? snapshots[cursor + 1] : nil
    }

    /// Classify a change the canvas just reported and move the history accordingly — see the type's doc comment.
    @discardableResult
    public mutating func record(_ bytes: Data) -> Outcome {
        if bytes == snapshots[cursor] {
            return .unchanged
        }
        if let target = undoTarget, bytes == target {
            cursor -= 1
            return .undone
        }
        if let target = redoTarget, bytes == target {
            cursor += 1
            return .redone
        }
        snapshots.removeSubrange((cursor + 1)...)
        snapshots.append(bytes)
        if snapshots.count > Self.maxDepth {
            snapshots.removeFirst(snapshots.count - Self.maxDepth)
        }
        cursor = snapshots.count - 1
        return .appended
    }

    /// Replace the current state's bytes without moving the cursor. For a programmatic reseed of the same ink — a
    /// re-projection on re-entry, say — whose bytes differ from the snapshot only because a projection round-trip is
    /// not byte-stable: the history is the same, only the current state's spelling changed. Without this the reseed
    /// would be recorded as a fresh edit, and undo would step back to the same ink.
    public mutating func rebase(current bytes: Data) {
        snapshots[cursor] = bytes
    }
}
