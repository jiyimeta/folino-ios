#if os(macOS)
import Domain

extension ReaderLayoutMode {
    /// The mode the Mac reader actually draws, for a stored `ReaderGlobalSettingsKey.layoutMode` raw value.
    ///
    /// The preference is shared with iOS by design, and iOS offers one mode the Mac has no container for:
    /// `horizontal`. That value therefore reads as `page`, the Mac's default. A read, never a write-back — clamping
    /// the stored value would silently retire a mode the user chose on their iPad.
    ///
    /// One definition rather than one per call site, because two call sites have to agree exactly:
    /// `MacReaderRootScreen` picks the container with it (and reports the same value as `currentLayoutMode`, so
    /// analytics can never name a mode that is not on screen), and `MacCommands` resolves the View ▸ Display Mode
    /// picker's selection with it — without that, a stored `horizontal` matches neither of the picker's two tags and
    /// the menu shows no checkmark at all while the screen is drawing Page.
    public static func macDisplayMode(storedRawValue raw: String) -> ReaderLayoutMode {
        let stored = ReaderLayoutMode(rawValue: raw) ?? .page
        return stored == .vertical ? .vertical : .page
    }
}
#endif
