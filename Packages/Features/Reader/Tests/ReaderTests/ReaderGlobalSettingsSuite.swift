import Testing

/// Parent suite for every test whose assertions depend on the Reader's process-global `UserDefaults` keys —
/// `ReaderGlobalSettingsKey.repeatMode` above all, which is sticky across scores by design.
///
/// `.serialized` because Swift Testing runs *suites* in parallel by default, and `.serialized` on a suite only
/// orders the tests inside it. Three suites wrote `repeatMode` and each cleared it in its own `init()`, which is
/// only sound against its own siblings: a concurrently-running suite could set `.loopAll` between another suite's
/// `init()` and its assertion. `PlaylistPlaybackProgression.nextAction` returns `.stop` for any mode but `.off`, so
/// the playlist advance under test simply never fired — measured, it had not fired 60 seconds later, which is why
/// this read as a timing flake and a longer deadline would not have helped. `RepeatModel` widens the window
/// further: it re-reads the global key on *any* `UserDefaults.didChangeNotification`, so a write to an unrelated
/// key elsewhere in the process is enough to pull a foreign mode in mid-test.
///
/// Nest such a suite in an extension of this type — `.serialized` covers nested suites — rather than declaring it
/// at file scope. Mirrors `AudioEngineTests` in InfrastructureTests, which exists for the same reason.
@Suite(.serialized)
struct ReaderGlobalSettingsTests {}
