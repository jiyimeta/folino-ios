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

/// Calls back when the output device the user was listening on goes away — headphones unplugged, a Bluetooth speaker
/// disconnecting, an AirPod case snapped shut.
///
/// macOS has no `AVAudioSession`, so there is no route-change notification and no `.oldDeviceUnavailable` reason to
/// filter on. The equivalent signal is CoreAudio's: when the device backing the system default output disappears,
/// CoreAudio reassigns `kAudioHardwarePropertyDefaultOutputDevice` to whatever remains (usually the built-in
/// speakers) and notifies listeners. `AVAudioEngine` follows the system default, so from the listener's point of
/// view that reassignment IS the disconnect — playback carries on out loud exactly as it does on iOS.
///
/// The macOS signal is deliberately broader than the iOS one: a change of default output also fires when the user
/// picks a different device themselves, in Sound settings or from the menu-bar volume control. Pausing there is the
/// same behavior the system's own media apps show, and it is the conservative direction to be wrong in — the user
/// hears silence and presses play, rather than hearing the score somewhere they did not choose.
///
/// Deliberately not `@MainActor`-isolated, and the listener block deliberately captures no `self`: the listener has
/// to be unregistered from `deinit`, which a `@MainActor` type cannot do for a non-`Sendable` stored property (an
/// `isolated deinit` would need a newer deployment target). CoreAudio may also have already dispatched a block by the
/// time `deinit` removes it, so a block reaching a deallocated owner has to be impossible by construction rather than
/// by timing — it holds only `onDisconnect`, whose own captures are the caller's business.
final class OutputRouteDisconnectWatcher {
    private let objectID = AudioObjectID(kAudioObjectSystemObject)
    /// Held so `deinit` can pass CoreAudio the exact same address it registered with.
    private var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain,
    )
    /// Held so `deinit` can pass CoreAudio the exact same block it registered with — `AudioObjectRemove-`
    /// `PropertyListenerBlock` matches on block identity, so a freshly written closure would remove nothing. Left
    /// `nil` when registration failed, so `deinit` does not ask CoreAudio to remove a listener it never took.
    private var listener: AudioObjectPropertyListenerBlock?

    /// - Parameter onDisconnect: invoked on the main actor when the current output device becomes unavailable.
    init(onDisconnect: @escaping @Sendable @MainActor () -> Void) {
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            // Dispatched on `.main` below, which for a main-actor callback is the main actor — but the block is
            // `@convention(block)` and so nominally non-isolated. Same hop the iOS body makes.
            MainActor.assumeIsolated {
                onDisconnect()
            }
        }
        guard AudioObjectAddPropertyListenerBlock(objectID, &address, .main, block) == noErr else { return }
        listener = block
    }

    deinit {
        if let listener {
            AudioObjectRemovePropertyListenerBlock(objectID, &address, .main, listener)
        }
    }
}
#endif
