import Foundation

/// Opt-in click tracing for the Mac score surfaces.
///
/// **Kept rather than removed after the zoom hit-testing bug, because it is what found it.** Two rounds of that
/// investigation turned on being able to see the point a click arrived at, the surface that received it and the item
/// it resolved to, in one line per click; reconstructing that from scratch each time is the expensive part.
///
/// Debug builds only, and silent unless `FOLINO_CLICK_TRACE=1` is set in the environment, so a normal debug run pays
/// one `Bool` read per click and prints nothing:
///
/// ```sh
/// FOLINO_CLICK_TRACE=1 .../folino.app/Contents/MacOS/folino 2>&1 | grep '\[click\]'
/// ```
///
/// Timestamps are `systemUptime`, which is monotonic — a wall clock can step backwards mid-session and ruin the one
/// thing a trace line is for, which is ordering.
func readerLogClick(_ message: @autoclosure () -> String) {
    #if DEBUG
    guard ReaderClickTrace.isEnabled else { return }
    print(String(format: "[click] t=%.3f %@", ProcessInfo.processInfo.systemUptime, message()))
    #endif
}

#if DEBUG
/// The trace's on/off switch, read once per process.
enum ReaderClickTrace {
    static let isEnabled = ProcessInfo.processInfo.environment["FOLINO_CLICK_TRACE"] == "1"
}
#endif
