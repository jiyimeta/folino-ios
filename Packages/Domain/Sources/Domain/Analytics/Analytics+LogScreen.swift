import UtilityCore

extension Analytics {
    /// Convenience for the manual `screen_view` event. Call from a top-level screen's `onAppear`.
    public func logScreen(_ screen: AnalyticsScreen) {
        log(.screen(screen))
    }
}
