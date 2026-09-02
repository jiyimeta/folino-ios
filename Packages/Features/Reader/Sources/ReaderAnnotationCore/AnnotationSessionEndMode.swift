/// What leaving an annotation session should offer to do — the three-way answer the strip's trailing control
/// renders, derived the same way the note-editing session derives its own (`EditorSessionEndMode`):
///
/// * `commitEdited` — this session put ink down or took it away. Leaving keeps it (it is already saved), and the
///   control says so in colour.
/// * `clearAll` — this session changed nothing, but the score carries ink from before. The only thing worth
///   offering is undoing the *previous* work: deleting every annotation on the score, which is the annotation
///   layer's "revert to original".
/// * `commitUnchanged` — nothing has ever been drawn. Leaving changes nothing.
///
/// The session's own changes win over the clear-all offer deliberately: mid-session, the thing you want is to keep or
/// drop what you just did, not to be offered a rollback of everything.
///
/// Platform-neutral so iOS and Android agree on which control they show; the Android strip derives its state from the
/// same two inputs.
public enum AnnotationSessionEndMode: Sendable, Equatable {
    case commitUnchanged
    case commitEdited
    case clearAll

    public static func derive(sessionHasChanges: Bool, hasInk: Bool) -> Self {
        if sessionHasChanges {
            return .commitEdited
        }
        if hasInk {
            return .clearAll
        }
        return .commitUnchanged
    }
}
