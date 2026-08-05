import Foundation

/// The capability stamp VocalTuner publishes at `vocaltuner/capabilities.json` in the shared App Group container.
///
/// folino reads it to decide whether the one-tap `vocaltuner://open-score` hand-off is available. No file, or a
/// `protocolVersion` below `VocalTunerAvailability.requiredProtocolVersion`, means fall back to the system share
/// sheet. This mirrors the `FolinoCapabilities` stamp folino writes for the inbound direction — the stamp is what
/// lets either side ship without a coordinated release.
public struct VocalTunerCapabilities: Codable, Sendable, Equatable {
    public let protocolVersion: Int
    public let vocalTunerAppVersion: String

    public init(protocolVersion: Int, vocalTunerAppVersion: String) {
        self.protocolVersion = protocolVersion
        self.vocalTunerAppVersion = vocalTunerAppVersion
    }
}

/// How far folino can go when handing a score to VocalTuner.
public enum VocalTunerAvailability: Equatable, Sendable {
    /// VocalTuner is not on the device. The share-menu row leads to its App Store page instead.
    case notInstalled
    /// Installed, but not advertising the hand-off protocol: no `vocaltuner/capabilities.json` stamp, or a stamp
    /// whose `protocolVersion` is below `requiredProtocolVersion`. This is why the share-sheet fallback is a normal
    /// path rather than an edge case.
    case installedLegacy
    /// Installed and speaking the hand-off protocol — the one-tap path.
    case installedHandoffCapable

    /// Version of the `IncomingScoresVT/<token>` contract folino stages for. VocalTuner must advertise at least
    /// this to get the deep-link path.
    public static let requiredProtocolVersion = 1

    /// Pure decision logic, kept out of the UIKit adapter so it is unit-testable.
    public static func resolve(
        canOpenVocalTuner: Bool,
        capabilities: VocalTunerCapabilities?,
    ) -> VocalTunerAvailability {
        guard canOpenVocalTuner else { return .notInstalled }
        guard let capabilities, capabilities.protocolVersion >= requiredProtocolVersion else {
            return .installedLegacy
        }
        return .installedHandoffCapable
    }
}

/// Outcome of a staged hand-off attempt. `.needsShareFallback` covers both "installed but legacy" and "staging
/// failed" — in either case the caller presents the ordinary share sheet for the file it already prepared, so the
/// user still gets the score across.
public enum VocalTunerHandoffResult: Equatable, Sendable {
    case openedViaDeepLink
    case needsShareFallback
}

/// Hands a prepared score file to VocalTuner. The live implementation lives in the App composition root because it
/// is the only part that touches UIKit and StoreKit; Features depend on this protocol only.
@MainActor
public protocol VocalTunerHandoff: Sendable {
    /// Re-read on every access rather than cached: VocalTuner can be installed, updated, or removed while folino
    /// sits in the background, and a stale answer would send the user down the wrong branch.
    var availability: VocalTunerAvailability { get }

    /// Stage `fileURL` into the shared container and open `vocaltuner://open-score`. `displayName` is the score's
    /// user-facing title, used to name the staged copy.
    ///
    /// `async` because the system's answer to "did the URL actually open?" only arrives after the fact: VocalTuner
    /// can be removed between the availability check and the tap, so `.openedViaDeepLink` must mean the open
    /// succeeded, not that it was requested. Anything else is `.needsShareFallback`.
    func openScore(fileURL: URL, displayName: String) async -> VocalTunerHandoffResult

    /// Present VocalTuner's App Store page in-app.
    func presentAppStore()
}

/// Inert default so previews and tests that don't exercise the companion hand-off need no extra argument.
/// Production injects `LiveVocalTunerHandoff` from the App composition root.
///
/// Lives here rather than once per Feature because both Library and Reader want the same default — a per-feature
/// copy would be the same five lines twice. `public` is earned: it genuinely crosses module boundaries.
@MainActor
public struct NoopVocalTunerHandoff: VocalTunerHandoff {
    public init() {}
    public var availability: VocalTunerAvailability {
        .notInstalled
    }

    /// Witnesses the protocol's `async` requirement synchronously — there is nothing to await when the answer is a
    /// constant.
    public func openScore(fileURL _: URL, displayName _: String) -> VocalTunerHandoffResult {
        .needsShareFallback
    }

    public func presentAppStore() {}
}
