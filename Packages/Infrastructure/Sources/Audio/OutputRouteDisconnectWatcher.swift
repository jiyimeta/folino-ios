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
