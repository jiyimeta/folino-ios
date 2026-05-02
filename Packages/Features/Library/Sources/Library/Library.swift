/// Module marker — referenced by smoke tests in App-level builds. The Library
/// module's real surface lives in `LibraryRootView`.
public enum LibraryModule {
    public static var isLinked: Bool { true }
}
