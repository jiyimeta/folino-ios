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
}
