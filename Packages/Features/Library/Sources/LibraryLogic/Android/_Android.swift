// Marker file: keeps LibraryLogic compilable when no other Android-only
// sources exist yet. Real Android sources land in Task 11.
#if os(Android)
@_documentation(visibility: internal)
public enum LibraryLogicAndroidMarker {}
#endif
