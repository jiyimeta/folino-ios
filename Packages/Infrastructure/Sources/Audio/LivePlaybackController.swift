// swiftlint:disable file_length
import Combine
import Domain
import Foundation
import MediaPlayer
import SheetMusicAudio
import SheetMusicCore
import UIKit

/// Bridges folino's `Domain.PlaybackController` onto
/// `SheetMusicAudio.PlaybackEngine`. The engine is `@MainActor` so this
/// adapter is too — the protocol's `async` methods become hops onto the
/// main actor.
@MainActor
public final class LivePlaybackController: Domain.PlaybackController {
    let engine: PlaybackEngine
    private let domainResolver: any Domain.SoundfontResolver
    private let precisionProbe: any Domain.PrecisePatchProbe
    /// Internal (not private) so the +LoopBounds extension file can reach
    /// it when forwarding to engine.play(in:) after a setLoop / clearLoop.
    var loadedScore: Score?
    /// Cursor the user picked while the engine's sequencer wasn't yet
    /// built (it's lazy — first `play(from:in:)` builds it). `seek` early-
    /// outs in that state, so we stash the request here and apply it on
    /// the next `play()` via `engine.play(from:in:)`. Without this, the
    /// first play after a tap-to-seek would reset to position 0 because
    /// `play(in:)` with `state == .stopped` rewinds the sequencer.
    private var pendingCursor: ScoreCursor?

    private var cursorHandler: (@MainActor (ScoreCursor?) -> Void)?
    private var cancellables: Set<AnyCancellable> = []
    /// Cached title / artist / default-rate for the loaded score. We
    /// rebuild the full `nowPlayingInfo` dictionary on every state
    /// change rather than mutating the live one in place — reading
    /// `MPNowPlayingInfoCenter.nowPlayingInfo` back can return a stale
    /// or nil snapshot, which would silently drop the rate update.
    private var nowPlayingMetadata: [String: Any] = [:]

    /// Bank / program of the bundled fallback patches. When a staff's
    /// precise SF2 is unavailable, the controller rewrites the staff's
    /// channel to one of these so the resolver's sync path returns the
    /// committed bundle file rather than an unrelated cached patch.
    static let pitchedFallbackChannel = (bank: 0, program: 73)
    static let drumFallbackChannel = (bank: 0, program: 0)

    public init(
        soundfontResolver: any SheetMusicAudio.SoundfontResolver,
        domainResolver: any Domain.SoundfontResolver,
        precisionProbe: any Domain.PrecisePatchProbe,
    ) {
        engine = PlaybackEngine(soundfontResolver: soundfontResolver)
        self.domainResolver = domainResolver
        self.precisionProbe = precisionProbe
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
        await Self.prefetchSoundfonts(score: score, resolver: domainResolver)
        // Prefetch's URLSession calls honor cancellation but the TaskGroup
        // returns regardless. Bail before the engine prepare so a cancel
        // mid-load doesn't end up with a primed engine the user expects to
        // be silent.
        try Task.checkCancellation()
        let prepared = Self.scoreWithFallbackRewrites(score, probe: precisionProbe)
        try engine.prepare(score: prepared)
        // `prepare` ends with `AVAudioEngine.start()` so the engine is running
        // even though `PlaybackState` is `.stopped`. iOS Control Center reads
        // the running engine as "audio is active" and overrides our
        // `MPNowPlayingInfoCenter.playbackState = .paused`, drawing the pause
        // glyph before the user has pressed play. Pausing the engine here
        // matches what `PlaybackEngine.pause()` does after a real pause —
        // sequencer is still nil (lazy), so this just stops the audio graph
        // and parks `state` at `.paused`.
        engine.pause()
        loadedScore = prepared
        pendingCursor = nil
        updateNowPlayingMetadata(for: prepared)
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

    /// Walks the score's distinct `(bank, program, isDrums)` triples and
    /// asks the resolver to materialise each on disk, in parallel.
    /// Soft-fails per patch — if one download 404s, the others still land.
    /// Patches that fail outright are handled later by
    /// `scoreWithFallbackRewrites` rewriting the staff channel.
    private static func prefetchSoundfonts(
        score: Score, resolver: any Domain.SoundfontResolver,
    ) async {
        let keys = distinctPatchKeys(in: score)
        await withTaskGroup(of: Void.self) { group in
            for key in keys {
                group.addTask {
                    _ = try? await resolver.resolveSoundfont(
                        bank: key.bank, program: key.program, isDrums: key.isDrums,
                    )
                }
            }
        }
    }

    public func areSoundfontsAvailableLocally(for score: Score) async -> Bool {
        let needed = Self.distinctPatchKeys(in: score)
        if needed.isEmpty { return true }
        let cachedKeys: Set<SoundfontPatchKey>
        do {
            let patches = try await domainResolver.cachedPatches()
            cachedKeys = Set(patches.map {
                SoundfontPatchKey(bank: $0.bank, program: $0.program, isDrums: $0.isDrums)
            })
        } catch {
            // If we can't enumerate the cache, fall back to "may need to
            // fetch" so the user gets the loading affordance instead of
            // a silent stall.
            return false
        }
        return needed.isSubset(of: cachedKeys)
    }

    public func isSoundfontCached(bank: Int, program: Int, isDrums: Bool) async -> Bool {
        do {
            let patches = try await domainResolver.cachedPatches()
            let needle = SoundfontPatchKey(bank: bank, program: program, isDrums: isDrums)
            return patches.contains { patch in
                SoundfontPatchKey(bank: patch.bank, program: patch.program, isDrums: patch.isDrums) == needle
            }
        } catch {
            // Match `areSoundfontsAvailableLocally`'s policy: if the cache
            // can't be enumerated, report "not cached" so callers surface
            // the loading affordance instead of stalling silently.
            return false
        }
    }

    public func prefetchSoundfont(bank: Int, program: Int, isDrums: Bool) async throws {
        _ = try await domainResolver.resolveSoundfont(
            bank: bank, program: program, isDrums: isDrums,
        )
    }

    private static func distinctPatchKeys(in score: Score) -> Set<SoundfontPatchKey> {
        var keys: Set<SoundfontPatchKey> = []
        for entry in score.allStaves {
            guard let part = score.part(at: entry.address) else { continue }
            let channel = part.instrument.channels.first ?? InstrumentChannel()
            let isDrums = part.instrument.useDrumset
            keys.insert(SoundfontPatchKey(
                bank: channel.bank, program: channel.program, isDrums: isDrums,
            ))
        }
        return keys
    }

    /// Returns a `Score` where every staff whose `(bank, program, isDrums)`
    /// has no precise SF2 file (cache or bundle) is rewritten to the
    /// matching bundled fallback channel (`(0, 73)` for pitched,
    /// `(0, 0)` for drums). Staves whose patch *is* available pass
    /// through unmodified.
    ///
    /// `swift-sheet-music`'s `Score` doesn't expose a `setPart(_:at:)`
    /// mutator — `parts` is a public mutable array — so this rewrites
    /// the part by index lookup off `StaffAddress.partIndex`.
    static func scoreWithFallbackRewrites(
        _ score: Score, probe: any Domain.PrecisePatchProbe,
    ) -> Score {
        var rewritten = score
        // Multi-staff parts (e.g. piano) yield multiple `allStaves` entries
        // sharing one `partIndex`. The precise-path check on the (already
        // rewritten) channel short-circuits subsequent visits — the rewrite
        // is idempotent per part, so the redundant probe call is the only
        // overhead.
        for entry in rewritten.allStaves {
            let partIndex = entry.address.partIndex
            guard rewritten.parts.indices.contains(partIndex) else { continue }
            let part = rewritten.parts[partIndex]
            let channel = part.instrument.channels.first ?? InstrumentChannel()
            let isDrums = part.instrument.useDrumset
            if probe.precisePath(
                forBank: channel.bank, program: channel.program, isDrums: isDrums,
            ) != nil {
                continue
            }
            let target = isDrums ? drumFallbackChannel : pitchedFallbackChannel
            var newChannel = channel
            newChannel.bank = target.bank
            newChannel.program = target.program
            // `Instrument.init` substitutes a default `[InstrumentChannel()]` when
            // given an empty channels array, so this branch is defensive — it only
            // fires if a caller mutates `channels = []` post-construction.
            if rewritten.parts[partIndex].instrument.channels.isEmpty {
                rewritten.parts[partIndex].instrument.channels = [newChannel]
            } else {
                rewritten.parts[partIndex].instrument.channels[0] = newChannel
            }
        }
        return rewritten
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
        engine.setMuted(forChannel: .metronome, to: !enabled)
    }

    public func setCursor(to cursor: ScoreCursor) {
        // `AVAudioSequencer` halts when `currentPositionInBeats` is written
        // during playback, which kills the engine's own cursor timer on its
        // next tick (`tickCursor` early-outs on `!sequencer.isPlaying`). To
        // preserve "playback continues from the seeked position", route
        // through `play(from:in:)` while playing — that path writes the
        // position AND calls `sequencer.start()` AND restarts the cursor
        // timer in lockstep. Pure `seek` is fine while paused / stopped.
        if engine.state == .playing, let score = loadedScore {
            engine.play(from: cursor, in: score)
            pendingCursor = nil
        } else {
            // `seek` is a no-op until the sequencer is built (first `play`
            // call), so always stash the request — `play()` consumes it.
            engine.seek(to: cursor)
            pendingCursor = cursor
        }
    }

    public func observeCursor(_ handler: @MainActor @escaping (ScoreCursor?) -> Void) {
        cursorHandler = handler
    }

    // setLoopRange lives in `LivePlaybackController+LoopBounds.swift`
    // alongside the cursor-mapping helpers it depends on (file_length
    // budget keeps `engine`-touching protocol methods split out).

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

        // Lock-screen / Control Center scrubber drag. iOS only fires this
        // when `MPMediaItemPropertyPlaybackDuration` is published, which we
        // already do in `publishNowPlayingInfo`. `engine.skip(by:)` clamps
        // to `[0, totalTimeSeconds]` and preserves play / pause state, so
        // forwarding the delta from the engine's current time is enough.
        // No-op until the sequencer has been built (first `play` call) —
        // before that, scrubbing is unreachable in practice because the
        // user has to press play to engage the lock-screen player.
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self,
                  let position = event as? MPChangePlaybackPositionCommandEvent
            else { return .commandFailed }
            MainActor.assumeIsolated {
                let delta = position.positionTime - self.engine.currentTimeSeconds
                self.engine.skip(by: delta)
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
    fileprivate var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
