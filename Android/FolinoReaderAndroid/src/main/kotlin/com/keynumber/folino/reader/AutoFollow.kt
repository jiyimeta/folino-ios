package com.keynumber.folino.reader

/**
 * Whether the Reader's playback-cursor auto-follow (auto-scroll in vertical/horizontal mode) should run
 * right now.
 *
 * `enabled` is the user's persistent opt-out (`SettingsPrefs.autoFollow` / `reader.autoFollow.enabled`,
 * default `true` — parity with iOS `readerAutoFollowEnabled`). When `false`, the auto-scroll effect skips
 * entirely: continuous playback no longer re-pins the viewport to the playhead, and a pause never
 * recenters a viewport the reader has scrolled away from.
 *
 * `isPlaying` restricts follow to continuous playback — there is nothing to auto-follow while paused /
 * stopped, so the caller's separate paused/manual keep-in-view path (unconditional on this predicate)
 * is what brings a manual seek on screen.
 *
 * `userInteracting` is true while the user is actively dragging or pinching the score, so a live touch
 * during playback is never fought by an automatic re-pin (Task 5); follow resumes as soon as the gesture
 * ends and this is evaluated again on the next cursor tick.
 *
 * Pure and Android/Compose-free so it is plain-JVM unit testable (see `AutoFollowTest`). Deliberately
 * simpler than iOS's `Domain.readerShouldFollowPlayback` (no session-scoped "suspended until resumed"
 * flag or manual-cursor-moved distinction) — see call sites in `ReaderScreen.kt` for how the paused/manual
 * keep-in-view branch is composed alongside this gate to reach the same user-facing behavior.
 */
fun shouldAutoFollow(enabled: Boolean, isPlaying: Boolean, userInteracting: Boolean): Boolean =
    enabled && isPlaying && !userInteracting
