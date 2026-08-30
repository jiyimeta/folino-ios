import Foundation
import ReaderInteractionCore

// swift-java (jextract) entry points for the Android Reader's coach marks.
//
// The engine behind these is `ReaderInteractionCore.ReaderHintEngine` — the same object iOS's `ReaderHintCoordinator`
// wraps. Which hint is due, whether this launch's budget is spent, when an offer rides a control's appearance, and
// when a hint retires for good are all decided there, once, for both platforms (parity — no divergent Kotlin port).
// Compose owns the bubble, the anchors it reports and the timers it runs; it decides nothing.
//
// Threading: everything here is main-thread-only, like the Compose UI that calls it. There is no lock, because
// every entry point is reached from a composable, an effect or a gesture callback on Android's main thread — the
// same contract iOS's `@MainActor` coordinator states in the type system.

/// Records what the engine asked to be offered later, for a host that owns its own timers.
///
/// A token per offer rather than a bare flag: Compose restarts its delay when the token changes and cancels it when
/// the token goes to zero, and a re-arm of an already-armed offer has to be distinguishable from one that simply
/// never lapsed.
private final class RecordingHintScheduler: ReaderHintScheduler {
    private(set) var tokens: [ReaderHintDeferredOffer: Int32] = [:]
    private var nextToken: Int32 = 0

    func schedule(_ offer: ReaderHintDeferredOffer, after _: Double) {
        // Wraps rather than overflows: only inequality is ever asked of a token, and a build would have to arm the
        // same offer two billion times to get back to a value the host is still holding.
        nextToken = nextToken == Int32.max ? 1 : nextToken + 1
        tokens[offer] = nextToken
    }

    func cancel(_ offer: ReaderHintDeferredOffer) {
        tokens[offer] = 0
    }

    /// The host has run the delay and called back; the schedule is spent whether or not the offer was still due.
    func markFired(_ offer: ReaderHintDeferredOffer) {
        tokens[offer] = 0
    }

    func token(_ offer: ReaderHintDeferredOffer) -> Int32 {
        tokens[offer] ?? 0
    }
}

/// The per-hint flags and the rotation cursor, in a small JSON file the host names once at startup.
///
/// Deliberately not Room and not the Kotlin preference store: these are a dozen booleans and one integer whose key
/// names are the engine's (`ReaderFeatureHint.usedKey`), and routing them through a `@WireletProvided` protocol would
/// add a codegen surface and an async store to something the engine has to be able to read *synchronously*, in the
/// middle of deciding which hint is due.
///
/// Reads are served from memory; a write rewrites the file. Losing the file loses nothing but "which coach marks have
/// been seen", which is why it is not worth a migration.
private final class FileHintPersistence: ReaderHintPersistence {
    private let url: URL
    private var bools: [String: Bool] = [:]
    private var ints: [String: Int32] = [:]

    init(path: String) {
        url = URL(fileURLWithPath: path)
        load()
    }

    private struct Snapshot: Codable {
        var bools: [String: Bool]
        var ints: [String: Int32]
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return }
        bools = snapshot.bools
        ints = snapshot.ints
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(Snapshot(bools: bools, ints: ints)) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
        )
        try? data.write(to: url, options: .atomic)
    }

    func bool(forKey key: String) -> Bool {
        bools[key] ?? false
    }

    func setBool(_ value: Bool, forKey key: String) {
        bools[key] = value
        save()
    }

    func integer(forKey key: String) -> Int32 {
        ints[key] ?? 0
    }

    func setInteger(_ value: Int32, forKey key: String) {
        ints[key] = value
        save()
    }

    func removeObject(forKey key: String) {
        bools[key] = nil
        ints[key] = nil
        save()
    }
}

/// The process-wide slot, matching iOS's `ReaderHintCoordinator.shared`: the one-hint-per-launch budget has to hold
/// across every score opened in this launch, which an instance owned by a screen could not do.
///
/// `nonisolated(unsafe)` states what the threading note above already does — main thread only, no lock.
private nonisolated(unsafe) var sharedScheduler = RecordingHintScheduler()
private nonisolated(unsafe) var sharedEngine: ReaderHintEngine?

/// Points the coach marks at their store. Idempotent: calling it again with the same path is a no-op, so the host can
/// call it from wherever it is convenient without tracking whether it already has.
///
/// Every other entry point below is inert until this has run, so a host that forgets it gets no coach marks rather
/// than a crash.
public func nativeHintConfigure(storePath: String) {
    guard sharedEngine == nil else { return }
    sharedScheduler = RecordingHintScheduler()
    sharedEngine = ReaderHintEngine(
        persistence: FileHintPersistence(path: storePath),
        scheduler: sharedScheduler,
    )
}

public func nativeHintSetAnchor(target: Int32, x: Double, y: Double, width: Double, height: Double) {
    guard let engine = sharedEngine, let target = ReaderHintTarget.fromWireValue(target) else { return }
    engine.setAnchor(ReaderHintRect(x: x, y: y, width: width, height: height), for: target)
}

public func nativeHintClearAnchor(target: Int32) {
    guard let engine = sharedEngine, let target = ReaderHintTarget.fromWireValue(target) else { return }
    engine.clearAnchor(for: target)
}

public func nativeHintClearAllAnchors() {
    sharedEngine?.clearAllAnchors()
}

public func nativeHintSetEditing(editing: Bool) {
    sharedEngine?.setEditing(editing)
}

public func nativeHintMarkUsed(hint: Int32) {
    guard let engine = sharedEngine, let hint = ReaderFeatureHint.fromWireValue(hint) else { return }
    engine.markUsed(hint)
}

public func nativeHintHasUsed(hint: Int32) -> Bool {
    guard let engine = sharedEngine, let hint = ReaderFeatureHint.fromWireValue(hint) else { return false }
    return engine.hasUsed(hint)
}

public func nativeHintOfferRotation() {
    sharedEngine?.offerRotationHint()
}

public func nativeHintOfferPadGesture() {
    sharedEngine?.offerPadGestureHint()
}

public func nativeHintSchedulePadMove() {
    sharedEngine?.schedulePadMoveHint()
}

/// The host's delay for `offer` (`ReaderHintDeferredOffer`: 0 transportExpand, 1 padRestore, 2 padMove) has elapsed.
/// The engine re-checks its own preconditions, so a callback for an offer that was meanwhile cancelled is a no-op.
public func nativeHintFireDeferredOffer(offer: Int32) {
    guard let engine = sharedEngine, let offer = readerHintDeferredOffer(wireValue: offer) else { return }
    sharedScheduler.markFired(offer)
    engine.fireDeferredOffer(offer)
}

public func nativeHintDismiss() {
    sharedEngine?.dismiss()
}

public func nativeHintRequestTransportModeSwitch() {
    sharedEngine?.requestTransportModeSwitch()
}

public func nativeHintReset() {
    sharedEngine?.reset()
}

public func nativeHintSetIgnoresPerLaunchBudget(value: Bool) {
    sharedEngine?.ignoresPerLaunchBudget = value
}

/// The whole slot in one read — see `ReaderHintStateWire`. Every state change is host-initiated, so re-reading this
/// after each call is enough to keep Compose in step; nothing changes behind its back.
public func nativeHintState() -> Data {
    guard let engine = sharedEngine else {
        return ReaderHintStateWire(
            presentedHint: ReaderFeatureHint.noHintWireValue,
            hasAnchor: false,
            anchorX: 0, anchorY: 0, anchorWidth: 0, anchorHeight: 0,
            transportModeSwitchRequests: 0,
            transportExpandSchedule: 0, padRestoreSchedule: 0, padMoveSchedule: 0,
            deferredOfferDelayMillis: Int32((ReaderHintEngine.appearanceOfferDelay * 1000).rounded()),
        ).encodeToData()
    }
    let hint = engine.presentedHint
    let anchor = hint.flatMap { engine.anchor(for: $0.target) }
    return ReaderHintStateWire(
        presentedHint: hint?.wireValue ?? ReaderFeatureHint.noHintWireValue,
        hasAnchor: anchor != nil,
        anchorX: anchor?.x ?? 0,
        anchorY: anchor?.y ?? 0,
        anchorWidth: anchor?.width ?? 0,
        anchorHeight: anchor?.height ?? 0,
        transportModeSwitchRequests: engine.transportModeSwitchRequests,
        transportExpandSchedule: sharedScheduler.token(.transportExpand),
        padRestoreSchedule: sharedScheduler.token(.padRestore),
        padMoveSchedule: sharedScheduler.token(.padMove),
        deferredOfferDelayMillis: Int32((ReaderHintEngine.appearanceOfferDelay * 1000).rounded()),
    ).encodeToData()
}

/// Where the bubble goes for `target`'s anchor in a viewport of this size — see `ReaderHintBubbleFrameWire`. Pure
/// delegation to `ReaderHintBubbleLayout.frame`, which SwiftUI's overlay calls with the same arguments.
public func nativeHintBubbleFrame(
    target: Int32,
    anchorX: Double,
    anchorY: Double,
    anchorWidth: Double,
    anchorHeight: Double,
    viewportWidth: Double,
    viewportHeight: Double,
) -> Data {
    let target = ReaderHintTarget.fromWireValue(target) ?? .annotationButton
    let frame = ReaderHintBubbleLayout.frame(
        anchor: ReaderHintRect(x: anchorX, y: anchorY, width: anchorWidth, height: anchorHeight),
        target: target,
        viewportWidth: viewportWidth,
        viewportHeight: viewportHeight,
    )
    return ReaderHintBubbleFrameWire(
        width: frame.width,
        originX: frame.originX,
        caretDX: frame.caretDX,
        placement: frame.placement.rawValue,
        edgeY: frame.edgeY,
    ).encodeToData()
}

/// The card's own measurements — see `ReaderHintBubbleMetricsWire`.
public func nativeHintBubbleMetrics() -> Data {
    ReaderHintBubbleMetricsWire(
        caretWidth: ReaderHintBubbleLayout.caretWidth,
        caretHeight: ReaderHintBubbleLayout.caretHeight,
        cornerRadius: ReaderHintBubbleLayout.cornerRadius,
        horizontalPadding: ReaderHintBubbleLayout.horizontalPadding,
        verticalPadding: ReaderHintBubbleLayout.verticalPadding,
        titleMessageSpacing: ReaderHintBubbleLayout.titleMessageSpacing,
        titleFontSize: ReaderHintBubbleLayout.titleFontSize,
        messageFontSize: ReaderHintBubbleLayout.messageFontSize,
        transitionDurationMillis: Int32((ReaderHintBubbleLayout.transitionDuration * 1000).rounded()),
        transitionScale: ReaderHintBubbleLayout.transitionScale,
    ).encodeToData()
}

/// `ReaderHintDeferredOffer` has a `String` raw value (it names a persistence-free concept, and the engine reads
/// better for it), so the wire numbering lives here rather than on the case list.
private func readerHintDeferredOffer(wireValue: Int32) -> ReaderHintDeferredOffer? {
    switch wireValue {
    case 0: .transportExpand
    case 1: .padRestore
    case 2: .padMove
    default: nil
    }
}
