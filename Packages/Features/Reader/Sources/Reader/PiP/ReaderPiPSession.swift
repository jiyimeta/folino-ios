import CoreGraphics
import Domain
import Foundation
import Observation
import SheetMusicCore

/// Snapshot of the layout inputs that determine PiP arm shape. Built by the view model at arm time so
/// every arm sees a consistent staffSize / hiddenStaves / clefOverrides triple, even if the user is
/// toggling staves rapidly.
struct PiPLayoutSnapshot {
    let staffSize: CGFloat
    let hiddenStaves: Set<StaffAddress>
    let clefOverrides: [StaffAddress: String]
    let transposeSemitones: Int
}

/// Wraps `ScorePiPCoordinator` with the session-lifecycle policy that previously lived inline in
/// `ReaderViewModel`: arm coalescing, dirty tracking when no observer would see the result, autostart
/// permission gating on `isPlaying`, and forced dismiss when AVKit-cached aspect ratios go stale.
@MainActor
@Observable
final class ReaderPiPSession {
    private(set) var isActive = false

    @ObservationIgnored private var coordinatorBacking: ScorePiPCoordinator?
    @ObservationIgnored private var isEnabled = false
    @ObservationIgnored private var collapseMultiMeasureRests = false
    @ObservationIgnored private var showInvisibleElements = false
    @ObservationIgnored private var showAllMeasureNumbers = false
    @ObservationIgnored private var pendingArmTask: Task<Void, Never>?
    @ObservationIgnored private var hasArmed = false
    @ObservationIgnored private var isDirty = false

    /// Providers — set by the owner (`ReaderViewModel`) right after init.
    var scoreProvider: () -> Score? = { nil }
    var isPlayingProvider: () -> Bool = { false }
    var playbackCursorProvider: () -> ScoreCursor? = { nil }
    var scrollAnchorCursorProvider: () -> ScoreCursor? = { nil }
    var layoutSnapshotProvider: () -> PiPLayoutSnapshot? = { nil }
    var playbackController: (any PlaybackController)?

    /// Triggered when the PiP HUD's play/pause button fires. The owner forwards into
    /// `playbackSession.togglePlayback()`.
    var onTogglePlayback: () async -> Void = {}

    static var isSupported: Bool {
        ScorePiPCoordinator.isSupported
    }

    var coordinator: ScorePiPCoordinator {
        if let c = coordinatorBacking {
            return c
        }
        let c = ScorePiPCoordinator()
        c.onPiPStarted = { [weak self] in self?.isActive = true }
        c.onPiPStopped = { [weak self] in self?.isActive = false }
        c.isAppPlayingProvider = { [weak self] in self?.isPlayingProvider() ?? false }
        c.onSetPlaying = { [weak self] desired in
            guard let self, isPlayingProvider() != desired else { return }
            Task { await self.onTogglePlayback() }
        }
        c.currentTimeProvider = { [weak self] in
            self?.playbackController?.currentTimeSeconds ?? 0
        }
        c.totalTimeProvider = { [weak self] in
            self?.playbackController?.totalTimeSeconds ?? 0
        }
        c.onSkip = { [weak self] seconds in
            guard let controller = self?.playbackController else { return }
            Task { await controller.skip(bySeconds: seconds) }
        }
        coordinatorBacking = c
        return c
    }

    func setEnabled(_ enabled: Bool) {
        guard Self.isSupported else { return }
        isEnabled = enabled
        applyAutoStart()
        if enabled {
            armIfReady()
        } else {
            pendingArmTask?.cancel()
            pendingArmTask = nil
            isDirty = false
            hasArmed = false
            dismissIfActive()
            coordinator.disarm()
        }
    }

    func setCollapseMultiMeasureRests(_ enabled: Bool) {
        guard collapseMultiMeasureRests != enabled else { return }
        collapseMultiMeasureRests = enabled
        armIfReady()
    }

    func setShowInvisibleElements(_ enabled: Bool) {
        guard showInvisibleElements != enabled else { return }
        showInvisibleElements = enabled
        armIfReady()
    }

    func setShowAllMeasureNumbers(_ enabled: Bool) {
        guard showAllMeasureNumbers != enabled else { return }
        showAllMeasureNumbers = enabled
        armIfReady()
    }

    /// No-ops when not active. Called from the Reader scenePhase observer on foreground return AND
    /// from the hidden-staves change handler (so AVKit renegotiates the PiP window aspect ratio on
    /// the next auto-start).
    func dismissIfActive() {
        guard isActive else { return }
        coordinator.dismissIfActive()
    }

    /// Owner calls this after `playbackSession.playbackCursor` updates.
    func notifyCursorChanged() {
        coordinatorBacking?.updatePlaybackCursor(playbackCursorProvider())
        coordinatorBacking?.updateScrollAnchorCursor(scrollAnchorCursorProvider())
    }

    /// Owner calls this after `playbackSession.isPlaying` flips.
    func onPlayingChanged(to playing: Bool) {
        applyAutoStart()
        if playing {
            flushDirtyIfNeeded()
        }
    }

    /// Coalesced rearm trigger. The heavy layout step inside `coordinator.arm` runs off the main
    /// actor, but it's wasted CPU when no observer would see the result. In that case the arm is
    /// postponed; `flushDirtyIfNeeded` consumes the postponement when an observer appears.
    ///
    /// The first arm of each `isEnabled` session always proceeds so a manual PiP start (via the
    /// system control) still finds a renderer attached.
    func armIfReady() {
        guard isEnabled, scoreProvider() != nil else { return }
        if !hasArmed || isActive || isPlayingProvider() {
            scheduleArm()
        } else {
            isDirty = true
        }
    }

    // MARK: - Private

    private func scheduleArm() {
        isDirty = false
        pendingArmTask?.cancel()
        pendingArmTask = Task { [weak self] in
            guard let self else { return }
            await performArm()
        }
    }

    private func flushDirtyIfNeeded() {
        guard isDirty else { return }
        scheduleArm()
    }

    /// The score a PiP frame engraves: the same display chain the on-screen reader runs, against the snapshot taken
    /// at arm time. Separated from `performArm` so it can be exercised without a coordinator.
    static func armScore(_ score: Score, snapshot: PiPLayoutSnapshot) -> Score {
        ReaderDisplayTransforms.display(
            score,
            clefOverrides: snapshot.clefOverrides,
            transposeSemitones: snapshot.transposeSemitones,
            hiddenStaves: snapshot.hiddenStaves,
        )
    }

    private func performArm() async {
        guard !Task.isCancelled,
              isEnabled,
              let score = scoreProvider(),
              let snapshot = layoutSnapshotProvider()
        else { return }
        let visible = Self.armScore(score, snapshot: snapshot)
        do {
            try await coordinator.arm(
                score: visible,
                staffSize: snapshot.staffSize,
                playbackCursor: playbackCursorProvider(),
                collapseMultiMeasureRests: collapseMultiMeasureRests,
                showInvisibleElements: showInvisibleElements,
                showAllMeasureNumbers: showAllMeasureNumbers,
            )
            hasArmed = true
        } catch is CancellationError {
            // Superseded by a newer rearm; nothing to do.
        } catch {
            // Coordinator throws only when no display layer is attached (the host view hasn't
            // mounted yet). Arming will retry once the view installs the layer and load() finishes —
            // neither ordering is fatal.
        }
    }

    private func applyAutoStart() {
        guard Self.isSupported else { return }
        coordinator.setAutoStartFromBackground(isEnabled && isPlayingProvider())
    }
}
