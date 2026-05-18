import Foundation

public enum ShareTokenURL {
    public static let scheme = "folino"
    public static let host = "import"

    public struct Parsed: Equatable, Sendable {
        public let token: UUID
        public let openAfter: Bool
    }

    public static func parse(_ url: URL) -> Parsed? {
        guard url.scheme == scheme, url.host == host else { return nil }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let items = components.queryItems ?? []
        guard let tokenString = items.first(where: { $0.name == "token" })?.value,
              let token = UUID(uuidString: tokenString) else { return nil }
        let openValue = items.first(where: { $0.name == "open" })?.value
        let openAfter = (openValue == "true" || openValue == "1")
        return Parsed(token: token, openAfter: openAfter)
    }

    public static func build(token: UUID, openAfter: Bool) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.queryItems = [
            URLQueryItem(name: "token", value: token.uuidString),
            URLQueryItem(name: "open", value: openAfter ? "true" : "false"),
        ]
        // Scheme + host + well-formed query items always yield a valid URL.
        // swiftlint:disable:next force_unwrapping
        return components.url!
    }
}
