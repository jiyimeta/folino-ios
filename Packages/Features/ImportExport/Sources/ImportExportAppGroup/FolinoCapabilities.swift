import Foundation

/// The capability stamp folino publishes at `folino/capabilities.json` in the shared App Group container.
///
/// Sibling apps read it to decide whether the one-tap `folino://open-score` hand-off is available: no file, or a
/// `protocolVersion` below the one they need, means fall back to a plain share sheet. Publishing the stamp is
/// therefore what flips a sibling from the fallback to one-tap — no coordinated release, the sibling just notices.
public struct FolinoCapabilities: Codable, Sendable, Equatable {
    /// Version of the `IncomingScores/<token>` hand-off contract this build implements. Bump only when a change
    /// would break a sibling built against the previous version.
    public static let currentProtocolVersion = 1

    public let protocolVersion: Int
    public let folinoAppVersion: String

    public init(protocolVersion: Int = FolinoCapabilities.currentProtocolVersion, folinoAppVersion: String) {
        self.protocolVersion = protocolVersion
        self.folinoAppVersion = folinoAppVersion
    }
}

/// Writes the capability stamp into the shared App Group container.
///
/// Rewritten on every launch rather than once: `folinoAppVersion` then self-corrects after an app update, a stamp
/// lost to a container reset comes back, and a future `protocolVersion` bump takes effect on the first launch of the
/// new build instead of waiting for some migration to notice.
public struct CapabilityStampWriter: Sendable {
    private let sharedContainer: URL

    public init(sharedContainer: URL) {
        self.sharedContainer = sharedContainer
    }

    public func stamp(appVersion: String) throws {
        let url = SharedScorePaths.capabilitiesURL(in: sharedContainer)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(
            FolinoCapabilities(folinoAppVersion: appVersion),
        )
        try data.write(to: url, options: .atomic)
    }
}
