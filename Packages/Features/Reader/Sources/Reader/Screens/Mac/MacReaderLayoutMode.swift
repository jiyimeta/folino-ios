#if os(macOS)
import Domain

extension ReaderLayoutMode {
    /// The mode the Mac reader actually draws, for a stored `ReaderGlobalSettingsKey.layoutMode` raw value.
    ///
    /// **It no longer folds anything, and that is the news.** The preference is shared with iOS by design, and until
    /// the Mac grew a horizontal container this read substituted `page` for `horizontal` so the screen would not be
    /// asked for a mode it could not draw. All three modes are real here now, so every stored value passes through
    /// and only an unrecognized one — a preference written by a future version, or a corrupted default — resolves to
    /// the Mac's default.
    ///
    /// One definition rather than one per call site, because two call sites have to agree exactly:
    /// `MacReaderRootScreen` picks the container with it (and reports the same value as `currentLayoutMode`, so
    /// analytics can never name a mode that is not on screen), and `MacCommands` resolves the View ▸ Display Mode
    /// picker's selection with it.
    public static func macDisplayMode(storedRawValue raw: String) -> ReaderLayoutMode {
        ReaderLayoutMode(rawValue: raw) ?? .page
    }
}
#endif
