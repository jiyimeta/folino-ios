import Combine
import Domain
import Foundation
import MediaPlayer
import SheetMusicAudio
import SheetMusicCore
#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

/// Bridges Folino's `Domain.PlaybackController` onto
/// `SheetMusicAudio.PlaybackEngine`. The engine is `@MainActor` so this
/// adapter is too — the protocol's `async` methods become hops onto the
/// main actor.
///
/// MVP scope: load → play / pause and per-staff volume forwarding. Cursor
/// streaming, A–B repeat, tempo multiplier, mute / solo / instrument
/// changes are stubbed pending UI demand.
@MainActor
public final class LivePlaybackController: Domain.PlaybackController {
    private let engine: PlaybackEngine
    private let domainResolver: (any Domain.SoundfontResolver)?
    private var loadedScore: Score?

    private var cursorHandler: (@MainActor (ScoreCursor?) -> Void)?
    private var cancellables: Set<AnyCancellable> = []
    /// Cached title / artist / default-rate for the loaded score. We
    /// rebuild the full `nowPlayingInfo` dictionary on every state
    /// change rather than mutating the live one in place — reading
    /// `MPNowPlayingInfoCenter.nowPlayingInfo` back can return a stale
    /// or nil snapshot, which would silently drop the rate update.
    private var nowPlayingMetadata: [String: Any] = [:]

    public init(
        soundfontResolver: any SheetMusicAudio.SoundfontResolver,
        domainResolver: (any Domain.SoundfontResolver)? = nil
    ) {
        engine = PlaybackEngine(soundfontResolver: soundfontResolver)
        self.domainResolver = domainResolver
        engine.$currentCursor
            .sink { [weak self] value in
                // Combine emits the engine's `@Published currentCursor` on
                // willSet, synchronously on the MainActor where the timer
                // task ran. Forward to the registered handler in the same
                // work item so each cursor change reaches SwiftUI without
                // an intervening Task hop. Routing through `AsyncStream` +
                // `for-await` instead let the consumer drain a buffered
                // burst in one work item, collapsing the intermediate
                // cursor positions before SwiftUI got a render slot
                // between them — visible as the cursor "skipping" past
                // chord onsets that the example app shows.
                self?.cursorHandler?(value)
            }
            .store(in: &cancellables)
        engine.$state
            .sink { [weak self] _ in
                self?.publishNowPlayingInfo()
            }
            .store(in: &cancellables)
        configureRemoteCommands()
    }

    public func load(score: Score, preferences: PlaybackPreferences) async throws {
        if let domainResolver {
            await Self.prefetchSoundfonts(score: score, resolver: domainResolver)
        }
        // Prefetch's URLSession calls honor cancellation but the TaskGroup
        // returns regardless. Bail before the engine prepare so a cancel
        // mid-load doesn't end up with a primed engine the user expects to
        // be silent.
        try Task.checkCancellation()
        try engine.prepare(score: score)
        loadedScore = score
        updateNowPlayingMetadata(for: score)
        for state in preferences.perStaff {
            engine.setVolume(
                forChannel: .staff(state.staffIndex), to: Float(state.volume)
            )
            engine.setMuted(
                forChannel: .staff(state.staffIndex), to: state.isMuted
            )
            engine.setSoloed(
                forChannel: .staff(state.staffIndex), to: state.isSolo
            )
        }
        engine.setRate(Float(preferences.tempoMultiplier))
    }

    /// Walks the score's distinct `(bank, program)` pairs and asks the
    /// resolver to materialise each on disk, in parallel. Soft-fails per
    /// patch — if one download 404s, the others still land and the engine
    /// just plays that voice silently.
    private static func prefetchSoundfonts(
        score: Score, resolver: any Domain.SoundfontResolver
    ) async {
        let keys = distinctPatchKeys(in: score)
        await withTaskGroup(of: Void.self) { group in
            for key in keys {
                group.addTask {
                    _ = try? await resolver.resolveSoundfont(
                        bank: key.bank, program: key.program
                    )
                }
            }
        }
    }

    public func areSoundfontsAvailableLocally(for score: Score) async -> Bool {
        // Only the bundled GM fallback is in play — nothing to fetch.
        guard let domainResolver else { return true }
        let needed = Self.distinctPatchKeys(in: score)
        if needed.isEmpty { return true }
        let cachedKeys: Set<SoundfontPatchKey>
        do {
            let patches = try await domainResolver.cachedPatches()
            cachedKeys = Set(patches.map { SoundfontPatchKey(bank: $0.bank, program: $0.program) })
        } catch {
            // If we can't enumerate the cache, fall back to "may need to
            // fetch" so the user gets the loading affordance instead of
            // a silent stall.
            return false
        }
        return needed.isSubset(of: cachedKeys)
    }

    private static func distinctPatchKeys(in score: Score) -> Set<SoundfontPatchKey> {
        var keys: Set<SoundfontPatchKey> = []
        for entry in score.allStaves {
            guard let part = score.part(at: entry.address) else { continue }
            let channel = part.instrument.channels.first ?? InstrumentChannel()
            keys.insert(SoundfontPatchKey(bank: channel.bank, program: channel.program))
        }
        return keys
    }

    public func play() throws {
        guard let score = loadedScore else { return }
        engine.play(in: score)
        publishNowPlayingInfo()
    }

    public func pause() {
        engine.pause()
        publishNowPlayingInfo()
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
            forChannel: .staff(staff), to: UInt8(clamping: program)
        )
    }

    public func setMetronomeEnabled(_ enabled: Bool) {
        engine.setMuted(forChannel: .metronome, to: !enabled)
    }

    public func setCursor(to cursor: ScoreCursor) {
        // `AVAudioSequencer` halts when `currentPositionInSeconds` is written
        // during playback, which kills the engine's own cursor timer on its
        // next tick (`tickCursor` early-outs on `!sequencer.isPlaying`). To
        // preserve "playback continues from the seeked position", route
        // through `play(from:in:)` while playing — that path writes the
        // position AND calls `sequencer.start()` AND restarts the cursor
        // timer in lockstep. Pure `seek` is fine while paused / stopped.
        if engine.state == .playing, let score = loadedScore {
            engine.play(from: cursor, in: score)
        } else {
            engine.seek(to: cursor)
        }
    }

    public func observeCursor(_ handler: @MainActor @escaping (ScoreCursor?) -> Void) {
        cursorHandler = handler
    }

    // Stub — engine doesn't expose loop ranges yet; keep the protocol whole.
    public func setLoopRange(_: ABRepeatRange?) {}

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
        // Disable togglePlayPause: with all three registered, iOS 17+
        // sometimes follows a Control Center pause tap with a synthesised
        // toggle event, which our handler would interpret as "state is
        // paused → resume" and immediately flip back to playing. Letting
        // play/pause be the only source of truth removes the race.
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

        // 10-second skip on lock screen / Control Center. The interval
        // also drives the glyph iOS draws on the buttons (the "10" badge).
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.preferredIntervals = [10]
        center.skipForwardCommand.addTarget { [weak self] event in
            guard let self,
                  let skip = event as? MPSkipIntervalCommandEvent
            else { return .commandFailed }
            MainActor.assumeIsolated {
                self.engine.skip(by: skip.interval)
                self.publishNowPlayingInfo()
            }
            return .success
        }
        center.skipBackwardCommand.addTarget { [weak self] event in
            guard let self,
                  let skip = event as? MPSkipIntervalCommandEvent
            else { return .commandFailed }
            MainActor.assumeIsolated {
                self.engine.skip(by: -skip.interval)
                self.publishNowPlayingInfo()
            }
            return .success
        }
    }

    private func updateNowPlayingMetadata(for score: Score) {
        let frameTexts = score.titleFrame?.texts ?? []
        let title = frameTexts.first(where: { $0.style == .title })?.text.nonEmpty
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

    /// App icon as `MPMediaItemArtwork`, used as the lock-screen /
    /// Control Center artwork. Looked up once via the canonical
    /// `CFBundleIcons` → `CFBundlePrimaryIcon` → `CFBundleIconFiles`
    /// path; `UIImage(named: "AppIcon")` doesn't resolve the processed
    /// icon at runtime. `nil` on platforms / hosts that don't ship one.
    private static let appIconArtwork: MPMediaItemArtwork? = {
        #if canImport(UIKit) && !os(watchOS)
            guard
                let icons = Bundle.main.infoDictionary?["CFBundleIcons"]
                as? [String: Any],
                let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
                let files = primary["CFBundleIconFiles"] as? [String],
                let name = files.last,
                let image = UIImage(named: name)
            else { return nil }
            return MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        #else
            return nil
        #endif
    }()

    /// Rebuild `nowPlayingInfo` from cached metadata + the engine's current
    /// state, and set the canonical `playbackState`. Always publishes a
    /// complete dictionary — partial updates that read `nowPlayingInfo` back
    /// have been observed to silently drop the rate change when the system
    /// returns nil mid-transition.
    private func publishNowPlayingInfo() {
        let isPlaying = engine.state == .playing
        var info = nowPlayingMetadata
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        // Duration + elapsed time drive the lock-screen scrubber. iOS
        // interpolates between the elapsed snapshot and the rate, so a
        // single publish on each state / skip change is enough — no
        // per-tick republish needed.
        info[MPMediaItemPropertyPlaybackDuration] = engine.totalTimeSeconds
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = engine.currentTimeSeconds
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        center.playbackState = isPlaying ? .playing : .paused
    }
}

extension String {
    fileprivate var nonEmpty: String? { isEmpty ? nil : self }
}
