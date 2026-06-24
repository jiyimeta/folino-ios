import Foundation

/// PiP window aspect ratio (width / height) derived from the rendered system's staff count.
///
/// Fewer staves → a flatter (wider) window; more staves → squarer, bottoming out at `minAspect`
/// (where the renderer shrinks the drawn music to fit the window height instead of growing the
/// window taller). Shared by iOS and Android (parity: one implementation; iOS calls this directly,
/// Android via the `FolinoReaderJNI` bridge — no divergent Kotlin port).
///
/// The heuristic is `aspectNumerator / staffCount`, clamped to `[minAspect, maxAspect]`. `maxAspect`
/// differs by platform: AVKit accepts up to `6.0` on iOS, while Android rejects any PiP aspect outside
/// ~`[1/2.39, 2.39]` and so passes a `2.34` ceiling. `minAspect` is `1.0` on both — the PiP window is
/// never taller than square; tall scores are handled by shrinking the music, not by a taller window.
public func pipWindowAspect(
    staffCount: Int,
    aspectNumerator: Double,
    minAspect: Double,
    maxAspect: Double,
) -> Double {
    let staves = Double(max(1, staffCount))
    return max(minAspect, min(maxAspect, aspectNumerator / staves))
}
