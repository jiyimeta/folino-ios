#if os(iOS)
@preconcurrency import AVFoundation
import Foundation

/// Calls back when the output device the user was listening on goes away — headphones unplugged, a Bluetooth speaker
/// disconnecting, an AirPod case snapped shut.
///
/// iOS reroutes such a change to the built-in speaker rather than stopping, so playback continues out loud in a room
/// the user chose headphones for. Every media app pauses instead; that is what `AVAudioSession`'s
/// `.oldDeviceUnavailable` reason exists to signal.
///
/// This lives in the app rather than in `swift-sheet-music` on purpose. An interruption leaves the engine's `state`
/// *wrong* — it claims `.playing` for audio iOS has already silenced — which only the engine can fix, and it does. A
/// route change leaves `state` perfectly accurate: playback really is still running, just somewhere the user did not
/// ask for. Whether to keep going there is a product decision, and it differs per app (a tuner re-asserts its own
/// speaker preference on this same notification instead of pausing).
///
/// Deliberately not `@MainActor`-isolated: the observer token has to be unregistered from `deinit`, which a
/// `@MainActor` type cannot do for a non-`Sendable` stored property (an `isolated deinit` would need a newer
/// deployment target). An unisolated owner can, and the callback still hops to the main actor.
final class OutputRouteDisconnectWatcher {
    private var token: (any NSObjectProtocol)?

    /// - Parameter onDisconnect: invoked on the main actor when the current output device becomes unavailable.
    init(onDisconnect: @escaping @Sendable @MainActor () -> Void) {
        token = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main,
        ) { notification in
            // Unwrap to the plain `UInt` HERE: `Notification` is not `Sendable`, so handing the notification itself
            // across to the main actor is a "sending risks causing data races" error even though the block already
            // runs on the main queue.
            let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            // `queue: .main` guarantees this block runs on the main thread, which for a main-actor callback is the
            // main actor — but the block is `@Sendable` and so nominally non-isolated.
            MainActor.assumeIsolated {
                guard rawReason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
                onDisconnect()
            }
        }
    }

    deinit {
        if let token {
            NotificationCenter.default.removeObserver(token)
        }
    }
}

#else
import CoreAudio
import Foundation
import os

/// Calls back when the output device the score was playing out of **disappears** — headphones unplugged, a Bluetooth
/// speaker disconnecting, an AirPod case snapped shut.
///
/// macOS has no `AVAudioSession`, so there is no route-change notification and no `.oldDeviceUnavailable` reason to
/// filter on. What this watches instead is a pair of CoreAudio properties on `kAudioObjectSystemObject`:
/// `kAudioHardwarePropertyDefaultOutputDevice` (where audio is going) and `kAudioHardwarePropertyDevices` (what
/// exists at all). `AVAudioEngine` follows the system default, so "the device that was the default has left the
/// device list" is the macOS spelling of `.oldDeviceUnavailable`.
///
/// **Both properties are needed; the default alone is not the signal.** On macOS, plugging a device IN usually makes
/// it the new default output, which moves `kAudioHardwarePropertyDefaultOutputDevice` exactly as unplugging one
/// does. Pausing on every move would therefore stop playback when the user connects headphones mid-score — the one
/// transition iOS explicitly plays through, since `.newDeviceAvailable` is filtered out by the iOS body above. So
/// the default moving is only ever a *question*; the device list is what answers it.
///
/// **Neither notification may be assumed to arrive first.** CoreAudio does not document an ordering between the two
/// properties, and this repo's audio history is ordering races, so the reconciliation is written to detect the
/// disconnect from whichever callback arrives holding the evidence:
///
/// - The device list lands first → the vanished id is in that callback's `removed` set, and it is still the recorded
///   `defaultOutput` because the default callback has not run yet. Reported there.
/// - The default lands first → the vanished id is not yet out of `knownDevices`, so it looks like a user switch. It
///   is parked in `unresolvedFormerDefault` rather than discarded, because that callback is the last place the old
///   id is known at all, and the device-list callback then finds it in `removed` and reports.
///
/// A parked id survives exactly one device-list change, so a deliberate output switch cannot leave the watcher
/// primed indefinitely. The residual gap is narrow and deliberate: switching output by hand and then unplugging the
/// device just switched away from, with no other device change in between, pauses once. That errs toward silence,
/// which is the safe direction.
///
/// **Breadth is also an interim hedge.** Until sub-project Ⅱ's ssm release handles `AVAudioEngineConfigurationChange`,
/// *any* Mac output-device change can leave `PlaybackEngine` in a bad state, so pausing somewhat readily is worth
/// more than precision. Revisit this breadth when that release lands — that is the trigger, not a date.
///
/// Deliberately not `@MainActor`-isolated: the listeners have to be unregistered from `deinit`, which a `@MainActor`
/// type cannot do for a non-`Sendable` stored property (an `isolated deinit` would need a newer deployment target).
///
/// The listener blocks therefore capture no `self` — they hold `RouteReconciler`, which owns every piece of mutable
/// state, and the caller's `onDisconnect`. CoreAudio may already have dispatched a block by the time `deinit` removes
/// it, so a block reaching a deallocated owner has to be impossible by construction rather than by timing: such a
/// block reconciles against a reconciler that is still alive and then calls an `onDisconnect` whose own `[weak self]`
/// has gone nil. (`AudioObjectPropertyListenerBlock` is `@Sendable`, so capturing the unisolated watcher even weakly
/// would not compile anyway — the split is what the concurrency checker wants as well as what teardown wants.)
final class OutputRouteDisconnectWatcher {
    private static let logger = Logger(subsystem: "com.KeyNumber.Folino", category: "PlaybackController")

    private let systemObject = AudioObjectID(kAudioObjectSystemObject)

    /// Held only because `AudioObjectAddPropertyListenerBlock` and `AudioObjectRemovePropertyListenerBlock` both take
    /// the address `inout`. Unlike the blocks below this is NOT an identity matter: CoreAudio copies the
    /// `AudioObjectPropertyAddress` value and matches on its fields, so an identical address rebuilt at teardown
    /// would match just as well. Storing it is a convenience, not a correctness requirement.
    private var defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain,
    )
    private var deviceListAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain,
    )

    // The registered blocks. These ARE an identity matter: `AudioObjectRemovePropertyListenerBlock` matches on the
    // block object, so an identical-looking closure written at teardown would remove nothing. Each stays `nil` when
    // its own registration failed, so teardown never asks CoreAudio to remove a listener it never took.
    private var defaultOutputListener: AudioObjectPropertyListenerBlock?
    private var deviceListListener: AudioObjectPropertyListenerBlock?

    /// Owns every piece of reconciliation state, so the listener blocks never have to capture the watcher itself.
    private let reconciler: RouteReconciler

    /// - Parameter onDisconnect: invoked on the main actor when the output device being played through disappears.
    init(onDisconnect: @escaping @Sendable @MainActor () -> Void) {
        let reconciler = RouteReconciler(onDisconnect: onDisconnect)
        self.reconciler = reconciler

        let defaultOutputBlock: AudioObjectPropertyListenerBlock = { _, _ in
            // Dispatched on `.main` below, which for a main-actor callback is the main actor — but the block is
            // `@convention(block)` and so nominally non-isolated. Same hop the iOS body makes.
            MainActor.assumeIsolated { reconciler.defaultOutputChanged() }
        }
        let deviceListBlock: AudioObjectPropertyListenerBlock = { _, _ in
            MainActor.assumeIsolated { reconciler.deviceListChanged() }
        }

        let defaultStatus = AudioObjectAddPropertyListenerBlock(
            systemObject, &defaultOutputAddress, .main, defaultOutputBlock,
        )
        if defaultStatus == noErr {
            defaultOutputListener = defaultOutputBlock
        } else {
            Self.logger.error(
                """
                OutputRouteDisconnectWatcher: default-output listener registration failed \
                (OSStatus \(defaultStatus)); playback will not pause when the output device disconnects
                """,
            )
        }

        let deviceListStatus = AudioObjectAddPropertyListenerBlock(
            systemObject, &deviceListAddress, .main, deviceListBlock,
        )
        if deviceListStatus == noErr {
            deviceListListener = deviceListBlock
        } else {
            Self.logger.error(
                """
                OutputRouteDisconnectWatcher: device-list listener registration failed \
                (OSStatus \(deviceListStatus)); a disconnect may be misread as a user-chosen output switch
                """,
            )
        }
    }

    deinit {
        if let defaultOutputListener {
            AudioObjectRemovePropertyListenerBlock(
                systemObject, &defaultOutputAddress, .main, defaultOutputListener,
            )
        }
        if let deviceListListener {
            AudioObjectRemovePropertyListenerBlock(systemObject, &deviceListAddress, .main, deviceListListener)
        }
    }
}

/// The watcher's mutable half, split out so the `@Sendable` listener blocks can capture it instead of the watcher.
/// `@MainActor` both because that is the queue CoreAudio delivers on and because it makes the type `Sendable`, which
/// is what lets a listener block hold it at all.
@MainActor
private final class RouteReconciler {
    private var knownDevices: Set<AudioDeviceID>
    private var defaultOutput: AudioDeviceID
    /// A device that stopped being the default while still listed. Either the user switched away from it, or its
    /// removal has not yet reached `kAudioHardwarePropertyDevices`; the next device-list change decides which.
    private var unresolvedFormerDefault: AudioDeviceID?
    private let onDisconnect: @Sendable @MainActor () -> Void

    /// `nonisolated` so the watcher — which is not `@MainActor`, so that its `deinit` can unregister — can seed the
    /// state at construction. Every stored value here is `Sendable`, so nothing escapes the actor by being set here.
    nonisolated init(onDisconnect: @escaping @Sendable @MainActor () -> Void) {
        self.onDisconnect = onDisconnect
        defaultOutput = readDefaultOutputDevice()
        knownDevices = readDeviceList() ?? []
    }

    /// The system default output moved. That on its own says nothing — the user may have picked a different device,
    /// or plugged one in and had macOS promote it. Only a device that is *gone* is a disconnect.
    func defaultOutputChanged() {
        let previous = defaultOutput
        defaultOutput = readDefaultOutputDevice()
        guard previous != AudioDeviceID(kAudioObjectUnknown), previous != defaultOutput else { return }
        if knownDevices.contains(previous) {
            // Still listed: either a user switch, or a removal the device-list property has not published yet. Park
            // it — this is the last callback in which the old id is known, so discarding it here would lose the
            // evidence for good.
            unresolvedFormerDefault = previous
        } else {
            unresolvedFormerDefault = nil
            onDisconnect()
        }
    }

    /// A device appeared or disappeared. This is where a disconnect is confirmed — against what actually left, not
    /// against what the default happens to be by now.
    func deviceListChanged() {
        // A failed read would look like every device vanishing at once, so leave the cached set alone instead.
        guard let updated = readDeviceList() else { return }
        let removed = knownDevices.subtracting(updated)
        knownDevices = updated

        if let suspect = unresolvedFormerDefault {
            // Resolved either way, which is what bounds a parked id to a single device-list change.
            unresolvedFormerDefault = nil
            if removed.contains(suspect) {
                onDisconnect()
                return
            }
        }

        // The device being played through left before CoreAudio republished the default itself.
        guard removed.contains(defaultOutput) else { return }
        defaultOutput = readDefaultOutputDevice()
        onDisconnect()
    }
}

private func readDefaultOutputDevice() -> AudioDeviceID {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain,
    )
    var deviceID = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID,
    )
    return status == noErr ? deviceID : AudioDeviceID(kAudioObjectUnknown)
}

/// `nil` on a failed read, which the caller must distinguish from "no devices" — treating a read failure as an empty
/// list would report every device as removed.
private func readDeviceList() -> Set<AudioDeviceID>? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain,
    )
    var size: UInt32 = 0
    let systemObject = AudioObjectID(kAudioObjectSystemObject)
    guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size) == noErr else { return nil }
    let capacity = Int(size) / MemoryLayout<AudioDeviceID>.size
    guard capacity > 0 else { return [] }
    var ids = [AudioDeviceID](repeating: AudioDeviceID(kAudioObjectUnknown), count: capacity)
    let status = AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &ids)
    guard status == noErr else { return nil }
    // `size` is rewritten with the bytes actually returned, which can be fewer than the probe reported.
    return Set(ids.prefix(Int(size) / MemoryLayout<AudioDeviceID>.size))
}
#endif
