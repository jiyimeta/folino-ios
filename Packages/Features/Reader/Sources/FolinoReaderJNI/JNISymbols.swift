import Domain

/// swift-java (jextract) entry point for the Android Reader's playback-cursor auto-scroll.
///
/// Pure delegation to the shared `Domain.scrollOffsetKeepingInView` so iOS and Android follow the playback cursor
/// with identical behavior from a single implementation (parity — no divergent Kotlin port). All values are in the
/// same coordinate space (scaled content pixels); the caller clamps against the trailing content extent.
public func nativeScrollOffsetKeepingInView(
    current: Double,
    targetMin: Double,
    targetMax: Double,
    viewport: Double,
    pad: Double,
) -> Double {
    scrollOffsetKeepingInView(
        current: current,
        targetMin: targetMin,
        targetMax: targetMax,
        viewport: viewport,
        pad: pad,
    )
}

/// swift-java (jextract) entry point for the Android Reader's horizontal
/// measure-anchored auto-scroll. Pure delegation to the shared
/// `Domain.horizontalMeasureScrollOffset` (parity — no divergent Kotlin port).
public func nativeHorizontalMeasureScrollOffset(
    current: Double,
    measureMin: Double,
    measureMax: Double,
    viewport: Double,
    pad: Double,
) -> Double {
    horizontalMeasureScrollOffset(
        current: current,
        measureMin: measureMin,
        measureMax: measureMax,
        viewport: viewport,
        pad: pad,
    )
}

/// swift-java (jextract) entry point for the Android Reader's playlist auto-advance. Pure delegation
/// to the shared `Domain.PlaylistPlaybackProgression.nextActionWire` so iOS and Android traverse
/// playlists identically from one implementation (parity — no divergent Kotlin port). Returns -1 for
/// `.stop`; a value >= 0 is the `.advance(toIndex:)` target in the live ordered playlist.
public func nativePlaylistNextAction(
    currentIndex: Int,
    count: Int,
    repeatModeRawValue: String,
    continuationRawValue: String,
) -> Int {
    PlaylistPlaybackProgression.nextActionWire(
        currentIndex: currentIndex,
        count: count,
        repeatModeRawValue: repeatModeRawValue,
        continuationRawValue: continuationRawValue,
    )
}
