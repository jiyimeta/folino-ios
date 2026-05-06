extension ReaderViewModel {
    /// How the reader lays out the score in the viewport. `.vertical`
    /// wraps systems to fit the view width and scrolls vertically;
    /// `.horizontal` lays the score out at its natural width as one
    /// long row that scrolls horizontally.
    public enum LayoutMode: String, CaseIterable, Sendable, Hashable {
        case vertical
        case horizontal
    }
}
