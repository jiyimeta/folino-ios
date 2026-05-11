import Foundation

public struct AppVersion: Hashable, Sendable, Comparable, CustomStringConvertible, RawRepresentable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(_ major: Int, _ minor: Int, _ patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public init?(_ string: String) {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        guard let major = Int(parts[0]),
              let minor = Int(parts[1]),
              let patch = Int(parts[2]) else { return nil }
        self.init(major, minor, patch)
    }

    public init?(rawValue: String) {
        self.init(rawValue)
    }

    public var rawValue: String {
        description
    }

    public var description: String {
        "\(major).\(minor).\(patch)"
    }

    public static let zero = AppVersion(0, 0, 0)

    public static let current: AppVersion = {
        let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        guard let v = AppVersion(raw) else {
            fatalError("CFBundleShortVersionString is missing or malformed: \(raw)")
        }
        return v
    }()

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}
