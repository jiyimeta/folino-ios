import SheetMusicLayoutApple

/// Installs the CoreText FontMetrics provider so `LayoutEngine`'s precondition passes in unit tests that exercise
/// layout. Reference `LayoutTestSupport.installed` from a layout-running test suite's `init()`.
enum LayoutTestSupport {
    static let installed: Void = { _ = SheetMusicLayoutApple.install }()
}
