/// Module marker — referenced by smoke tests in App-level builds. The Library module's real surface lives in
/// `LibraryRootScreen`.
enum LibraryModule {
    static var isLinked: Bool {
        true
    }
}
