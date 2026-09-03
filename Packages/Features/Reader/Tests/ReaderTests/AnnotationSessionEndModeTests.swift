import ReaderAnnotationCore
import Testing

/// The strip's trailing control is the whole status readout for an annotation session, and it has to agree with the
/// note-editing session's rules: the session's own changes win, an untouched score with prior ink offers clear-all,
/// and an untouched score with no ink is quiet.
@Suite("Annotation session end mode")
struct AnnotationSessionEndModeTests {
    @Test func `a session that changed nothing on a score with no ink commits quietly`() {
        #expect(AnnotationSessionEndMode.derive(sessionHasChanges: false, hasInk: false) == .commitUnchanged)
    }

    @Test func `a session that changed nothing on an inked score offers to clear everything`() {
        #expect(AnnotationSessionEndMode.derive(sessionHasChanges: false, hasInk: true) == .clearAll)
    }

    @Test func `a session with changes commits edited, whether or not there was ink before`() {
        #expect(AnnotationSessionEndMode.derive(sessionHasChanges: true, hasInk: false) == .commitEdited)
        #expect(AnnotationSessionEndMode.derive(sessionHasChanges: true, hasInk: true) == .commitEdited)
    }

    /// The raw values are a wire contract, not an implementation detail: `nativeAnnotationSessionEndMode` hands them
    /// across JNI and Kotlin's own `AnnotationSessionEndMode.fromRawValue` maps them back by ordinal. Renumbering a
    /// case here would silently make Android show a different control — the `.so` and the Kotlin would disagree with
    /// no link error to catch it — so the numbers are pinned on both sides. Kotlin's half is
    /// `AnnotationSessionEndModeTest`.
    @Test func `the raw values are the JNI wire contract with Kotlin's ordinals`() {
        #expect(AnnotationSessionEndMode.commitUnchanged.rawValue == 0)
        #expect(AnnotationSessionEndMode.commitEdited.rawValue == 1)
        #expect(AnnotationSessionEndMode.clearAll.rawValue == 2)
    }
}
