import Foundation
import ImportExportAppGroup

/// Parses the cross-app one-tap hand-off URL `folino://open-score?token=<token>[&open=<bool>]`, which a sibling app
/// opens right after staging a score under `IncomingScores/<token>/` in the shared App Group.
///
/// Mirrors `ShareTokenURL` (folino's own Share-Extension hand-off, on host `import`) with two contract differences:
/// the token is an opaque `String` rather than a `UUID`, and `open` defaults to **true** when the parameter is
/// absent — the shipped sibling omits it, and an app that bothered to open this URL wants the score on screen.
public enum OpenScoreURL {
    public static let scheme = "folino"
    public static let host = "open-score"

    public struct Parsed: Equatable, Sendable {
        public let token: String
        public let openAfter: Bool
    }

    public static func parse(_ url: URL) -> Parsed? {
        guard url.scheme == scheme, url.host == host else { return nil }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let items = components.queryItems ?? []
        // A token that is not a safe path component is rejected outright rather than sanitized: the only producer is
        // a sibling app writing UUID strings, so anything else is malformed and has no correct staged directory.
        guard let token = items.first(where: { $0.name == "token" })?.value,
              SharedScorePaths.isValidToken(token) else { return nil }
        let openValue = items.first(where: { $0.name == "open" })?.value
        let openAfter = openValue.map { $0 == "true" || $0 == "1" } ?? true
        return Parsed(token: token, openAfter: openAfter)
    }
}
