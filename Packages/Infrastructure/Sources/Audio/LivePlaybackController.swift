import AVFoundation
import Domain
import Foundation
import MediaPlayer
import Observation
import os
import SheetMusicAudio
import SheetMusicCore
import UIKit

/// Bridges folino's `Domain.PlaybackController` onto `SheetMusicAudio.PlaybackEngine`. The engine is `@MainActor` so
/// this adapter is too — the protocol's `async` methods become hops onto the main actor.
@MainActor
public final class LivePlaybackController: Domain.PlaybackController {
    let engine: PlaybackEngine
    /// Internal (not private) so the +LoopBounds extension file can reach it when forwarding to engine.play(in:) after
    /// a setLoop / clearLoop.
    var loadedScore: Score?
    /// Cached preferences from the most recent `load(...)` — replayed against the engine during `reloadSoundfont()` so
    /// per-staff volumes / mutes / solos / tempo survive the soundfont swap. Internal so the +Reload extension can
    /// reach it.
    var loadedPreferences: PlaybackPreferences?
    /// Cursor the user picked while the engine's sequencer wasn't yet built (it's lazy — first `play(from:in:)` builds
    /// it). `seek` early-outs in that state, so we stash the request here and apply it on the next `play()` via
    /// `engine.play(from:in:)`. Without this, the first play after a tap-to-seek would reset to position 0 because
    /// `play(in:)` with `state == .stopped` rewinds the sequencer. Internal so the +Reload extension can stash a
    /// pending cursor after re-prepare.
    var pendingCursor: ScoreCursor?

    private var cursorHandler: (@MainActor (ScoreCursor?) -> Void)?
    private var isPlayingHandler: (@MainActor (Bool) -> Void)?
    /// Tasks consuming `Observations` streams over the engine's observable `currentCursor` / `state`. Cancelled in
    /// `deinit` so the loops drop their strong engine reference and exit. Stored separately (rather than as a set) so
    /// each can be reasoned about and torn down explicitly.
    private var cursorObservationTask: Task<Void, Never>?
    private var stateObservationTask: Task<Void, Never>?
    /// Last engine time we observed on the cursor stream. Used to detect backward jumps (A-B loop wrap) and re-publish
    /// `nowPlayingInfo` so the lock-screen scrubber follows the wrap. iOS interpolates the scrubber from the last
    /// published elapsed snapshot + rate, so without an extra publish on wrap the lock screen keeps advancing past B
    /// even though audio and in-app cursor jumped back to A.
    private var lastObservedEngineTime: TimeInterval = 0
    /// Cached title / artist / default-rate for the loaded score. We rebuild the full `nowPlayingInfo` dictionary on
    /// every state change rather than mutating the live one in place — reading `MPNowPlayingInfoCenter.nowPlayingInfo`
    /// back can return a stale or nil snapshot, which would silently drop the rate update.
    private var nowPlayingMetadata: [String: Any] = [:]
    /// Cached metronome-enabled flag. Mirrors what was last passed to `setMetronomeEnabled(_:)`. `prepare(score:)`
    /// resets the engine's metronome to its default of enabled, so `reloadSoundfont()` re-applies this. Internal so
    /// the +Reload extension can read it.
    var metronomeEnabled = true
    let logger = Logger(subsystem: "com.KeyNumber.Folino", category: "PlaybackController")

    public init(soundfontResolver: any SheetMusicAudio.SoundfontResolver) {
        engine = PlaybackEngine(soundfontResolver: soundfontResolver)
        startObservingEngine()
        configureRemoteCommands()
    }

    deinit {
        cursorObservationTask?.cancel()
        stateObservationTask?.cancel()
    }

    /// Subscribe to the engine's observable `currentCursor` / `state` via the `Observation` framework. `PlaybackEngine`
    /// is `@Observable`, so we open an `Observations` stream per property and consume successive snapshots on the main
    /// actor — replacing the Combine `$currentCursor` / `$state` publishers we used before the engine migrated.
    ///
    /// `Observations` yields the latest value when any observed dependency changes; between awaits it coalesces
    /// intermediate writes. The engine ticks the cursor once per chord / rest step and SwiftUI gets a render slot
    /// between iterations on the main actor, so in practice this preserves the per-step delivery the cursor highlight
    /// depends on. If a future engine tick burst (e.g. fast-tempo wrap with multiple cursor moves inside one main-actor
    /// work item) ever collapses visible chord onsets, the handler signature is small enough to swap to a synchronous
    /// observation primitive without changing the `PlaybackController` protocol contract.
    private func startObservingEngine() {
        let engine = engine
        cursorObservationTask = Task { @MainActor [weak self] in
            let stream = Observations { engine.currentCursor }
            for await cursor in stream {
                guard let self else { return }
                let now = engine.currentTimeSeconds
                if now < lastObservedEngineTime {
                    // A-B loop wrap (or any other engine-driven backward jump) — re-publish so the lock-screen scrubber
                    // resets to the new elapsed time instead of continuing to interpolate past B.
                    publishNowPlayingInfo(seeking: true)
                }
                lastObservedEngineTime = now
                cursorHandler?(cursor)
            }
        }
        stateObservationTask = Task { @MainActor [weak self] in
            let stream = Observations { engine.state }
            for await state in stream {
                guard let self else { return }
                publishNowPlayingInfo()
                isPlayingHandler?(state == .playing)
            }
        }
    }

    public func load(
        score: Score, displayTitle: String?, preferences: PlaybackPreferences,
    ) throws {
        try engine.prepare(score: score)
        // `prepare` ends with `AVAudioEngine.start()` so the engine is running even though `PlaybackState` is
        // `.stopped`. iOS Control Center reads the running engine as "audio is active" and overrides our
        // `MPNowPlayingInfoCenter.playbackState = .paused`, drawing the pause glyph before the user has pressed play.
        // Pausing the engine here matches what `PlaybackEngine.pause()` does after a real pause — sequencer is still
        // nil (lazy), so this just stops the audio graph and parks `state` at `.paused`.
        engine.pause()
        loadedScore = score
        loadedPreferences = preferences
        pendingCursor = nil
        updateNowPlayingMetadata(for: score, displayTitle: displayTitle)
        applyPreferences(preferences)
    }

    // `reloadSoundfont` lives in `LivePlaybackController+Reload.swift` — it needs the cached `loadedPreferences` and
    // `metronomeEnabled` declared above plus `applyPreferences` / `publishNowPlayingInfo` below, but is otherwise
    // self-contained.

    func applyPreferences(_ preferences: PlaybackPreferences) {
        for state in preferences.perStaff {
            engine.setVolume(
                forChannel: .staff(state.staffIndex), to: Float(state.volume),
            )
            engine.setMuted(
                forChannel: .staff(state.staffIndex), to: state.isMuted,
            )
            engine.setSoloed(
                forChannel: .staff(state.staffIndex), to: state.isSolo,
            )
        }
        engine.setRate(Float(preferences.tempoMultiplier))
    }

    public func play() throws {
        guard let score = loadedScore else { return }
        engine.play(from: pendingCursor, in: score)
        pendingCursor = nil
        publishNowPlayingInfo()
    }

    public func pause() {
        engine.pause()
        publishNowPlayingInfo()
    }

    public func releaseEngine() {
        // `engine.prepare(score:)` ends with `AVAudioEngine.start()` and only pauses it afterwards. iOS treats a
        // `.playback` session — active or paused — as ongoing audio output and inhibits screen auto-lock for the rest
        // of the app's lifetime. Teardown stops the underlying AVAudioEngine and releases samplers; the session is
        // then explicitly demoted to `.ambient` and deactivated so the system resumes normal idle-timer behavior. The
        // next `load(score:...)` re-primes everything (engine.prepare sets the category back to `.playback`).
        engine.teardown()
        loadedScore = nil
        loadedPreferences = nil
        pendingCursor = nil
        lastObservedEngineTime = 0
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        try? session.setCategory(.ambient, mode: .default, options: [])
    }

    public var currentTimeSeconds: TimeInterval {
        engine.currentTimeSeconds
    }

    public var totalTimeSeconds: TimeInterval {
        engine.totalTimeSeconds
    }

    public func skip(bySeconds seconds: TimeInterval) {
        engine.skip(by: seconds)
        publishNowPlayingInfo(seeking: true)
    }

    public func setStaffVolume(staff: Int, volume: Double) {
        engine.setVolume(forChannel: .staff(staff), to: Float(volume))
    }

    public func setStaffMute(staff: Int, isMuted: Bool) {
        engine.setMuted(forChannel: .staff(staff), to: isMuted)
    }

    public func setStaffSolo(staff: Int, isSolo: Bool) {
        engine.setSoloed(forChannel: .staff(staff), to: isSolo)
    }

    public func setStaffInstrument(staff: Int, bank _: Int, program: Int) {
        engine.setProgram(
            forChannel: .staff(staff), to: UInt8(clamping: program),
        )
    }

    public func setMetronomeEnabled(_ enabled: Bool) {
        metronomeEnabled = enabled
        engine.setMuted(forChannel: .metronome, to: !enabled)
    }

    public func setCursor(to cursor: ScoreCursor) {
        // `AVAudioSequencer` halts when `currentPositionInBeats` is written during playback, which kills the engine's
        // own cursor timer on its next tick (`tickCursor` early-outs on `!sequencer.isPlaying`). To preserve "playback
        // continues from the seeked position", route through `play(from:in:)` while playing — that path writes the
        // position AND calls `sequencer.start()` AND restarts the cursor timer in lockstep. Pure `seek` is fine while
        // paused / stopped.
        if engine.state == .playing, let score = loadedScore {
            engine.play(from: cursor, in: score)
            pendingCursor = nil
        } else {
            // `seek` is a no-op until the sequencer is built (first `play` call), so always stash the request —
            // `play()` consumes it.
            engine.seek(to: cursor)
            pendingCursor = cursor
        }
    }

    public func observeCursor(_ handler: @MainActor @escaping (ScoreCursor?) -> Void) {
        cursorHandler = handler
    }

    public func observeIsPlaying(_ handler: @MainActor @escaping (Bool) -> Void) {
        isPlayingHandler = handler
        // Seed with the current state so the consumer doesn't have to wait for the next engine transition to learn
        // whether the engine is already playing.
        handler(engine.state == .playing)
    }

    // setLoopRange lives in `LivePlaybackController+LoopBounds.swift` alongside the cursor-mapping helpers it depends
    // on (file_length budget keeps `engine`-touching protocol methods split out).

    public func setTempoMultiplier(_ value: Double) {
        engine.setRate(Float(value))
    }

    // MARK: - Now Playing / Remote Commands

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.skipForwardCommand.removeTarget(nil)
        center.skipBackwardCommand.removeTarget(nil)
        center.changePlaybackPositionCommand.removeTarget(nil)
        // Disable togglePlayPause: with all three registered, iOS 17+ sometimes follows a Control Center pause tap with
        // a synthesised toggle event, which our handler would interpret as "state is paused → resume" and immediately
        // flip back to playing. Letting play/pause be the only source of truth removes the race.
        center.togglePlayPauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.isEnabled = false

        center.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            return MainActor.assumeIsolated {
                do {
                    try self.play()
                    return .success
                } catch {
                    return .commandFailed
                }
            }
        }
        center.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            MainActor.assumeIsolated { self.pause() }
            return .success
        }

        // 10-second skip on lock screen / Control Center. The interval also drives the glyph iOS draws on the buttons
        // (the "10" badge).
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.preferredIntervals = [10]
        center.skipForwardCommand.addTarget { [weak self] event in
            guard let self,
                  let skip = event as? MPSkipIntervalCommandEvent
            else { return .commandFailed }
            MainActor.assumeIsolated {
                self.engine.skip(by: skip.interval)
                self.publishNowPlayingInfo(seeking: true)
            }
            return .success
        }
        center.skipBackwardCommand.addTarget { [weak self] event in
            guard let self,
                  let skip = event as? MPSkipIntervalCommandEvent
            else { return .commandFailed }
            MainActor.assumeIsolated {
                self.engine.skip(by: -skip.interval)
                self.publishNowPlayingInfo(seeking: true)
            }
            return .success
        }

        // Lock-screen / Control Center scrubber drag. iOS only fires this when `MPMediaItemPropertyPlaybackDuration` is
        // published, which we already do in `publishNowPlayingInfo`. `engine.skip(by:)` clamps to `[0,
        // totalTimeSeconds]` and preserves play / pause state, so forwarding the delta from the engine's current time
        // is enough. No-op until the sequencer has been built (first `play` call) — before that, scrubbing is
        // unreachable in practice because the user has to press play to engage the lock-screen player.
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self,
                  let position = event as? MPChangePlaybackPositionCommandEvent
            else { return .commandFailed }
            MainActor.assumeIsolated {
                let delta = position.positionTime - self.engine.currentTimeSeconds
                self.engine.skip(by: delta)
                self.publishNowPlayingInfo(seeking: true)
            }
            return .success
        }
    }

    private func updateNowPlayingMetadata(for score: Score, displayTitle: String?) {
        let frameTexts = score.titleFrame?.texts ?? []
        let title = displayTitle?.nonEmpty
            ?? frameTexts.first(where: { $0.style == .title })?.text.nonEmpty
            ?? score.metaTags["workTitle"]?.nonEmpty
            ?? "Untitled"
        let composer = frameTexts.first(where: { $0.style == .composer })?.text.nonEmpty
            ?? score.metaTags["composer"]?.nonEmpty

        var meta: [String: Any] = [:]
        meta[MPMediaItemPropertyTitle] = title
        if let composer {
            meta[MPMediaItemPropertyArtist] = composer
        }
        meta[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        if let artwork = Self.appIconArtwork {
            meta[MPMediaItemPropertyArtwork] = artwork
        }
        nowPlayingMetadata = meta
        publishNowPlayingInfo()
    }

    /// App icon as `MPMediaItemArtwork`, used as the lock-screen / Control Center artwork. Looked up once via the
    /// canonical `CFBundleIcons` → `CFBundlePrimaryIcon` → `CFBundleIconFiles` path; `UIImage(named: "AppIcon")`
    /// doesn't resolve the processed icon at runtime. `nil` on platforms / hosts that don't ship one.
    private static let appIconArtwork: MPMediaItemArtwork? = {
        guard
            let icons = Bundle.main.infoDictionary?["CFBundleIcons"]
            as? [String: Any],
            let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
            let files = primary["CFBundleIconFiles"] as? [String],
            let name = files.last,
            let image = UIImage(named: name)
        else { return nil }
        return MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }()

    /// Rebuild `nowPlayingInfo` from cached metadata + the engine's current state, and set the canonical
    /// `playbackState`. Always publishes a complete dictionary — partial updates that read `nowPlayingInfo` back have
    /// been observed to silently drop the rate change when the system returns nil mid-transition.
    ///
    /// `seeking` flag — for engine-driven backward jumps (A-B loop wrap) and explicit seeks. iOS doesn't honour a
    /// decreasing `elapsedPlaybackTime` with `playbackRate` held at 1.0 (the lock screen scrubber keeps extrapolating
    /// forward from the previous snapshot). The workaround is to publish with `rate = 0` first to force iOS to commit
    /// the new elapsed value, then re-publish with the real rate so playback continues. Apple's MusicKit /
    /// AVPlayer-backed apps do this implicitly via `playbackState` transitions, which third-party apps can't write
    /// directly.
    func publishNowPlayingInfo(seeking: Bool = false) {
        let isPlaying = engine.state == .playing
        let elapsed = engine.currentTimeSeconds
        let center = MPNowPlayingInfoCenter.default()
        var info = nowPlayingMetadata
        info[MPMediaItemPropertyPlaybackDuration] = engine.totalTimeSeconds
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        if seeking, isPlaying {
            // Two-step publish: first park the rate at 0 with the new elapsed so iOS records the snapshot, then resume
            // rate = 1 so extrapolation continues from the snapped position.
            info[MPNowPlayingInfoPropertyPlaybackRate] = 0.0
            center.nowPlayingInfo = info
        }
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        center.nowPlayingInfo = info
        center.playbackState = isPlaying ? .playing : .paused
        // Resync the cursor-sink's backward-jump detector so the next tick after an explicit publish (skip / seek /
        // state change) doesn't re-trigger a redundant publish.
        lastObservedEngineTime = elapsed
    }
}

extension String {
    fileprivate var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
