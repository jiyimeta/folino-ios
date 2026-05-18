import Foundation

/// Synchronous "is this patch precisely cached or bundled?" probe. Separate from the async `SoundfontResolver` because
/// the playback controller's fallback-rewrite decision must happen synchronously between async prefetch and
/// `engine.prepare(score:)`.
public protocol PrecisePatchProbe: Sendable {
    /// Returns the URL of a precisely-matching `.sf2` file (cache or bundle hit). Returns `nil` when no precise file
    /// exists, even if a fallback would be served by the async / non-precise resolver.
    func precisePath(forBank bank: Int, program: Int, isDrums: Bool) -> URL?
}
