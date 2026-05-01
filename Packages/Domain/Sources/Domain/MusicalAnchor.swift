import Foundation

/// A rectangle in normalized coordinates. All fields are clamped to [0, 1] and
/// (x + width) / (y + height) are clamped not to exceed 1.
public struct UnitRect: Hashable, Sendable, Codable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        let clampedX = Self.round10(min(max(x, 0), 1))
        let clampedY = Self.round10(min(max(y, 0), 1))
        // Only fit-clamp size when the origin is inside [0, 1) so that an
        // out-of-bounds origin (e.g. y = 1.2) does not collapse the dimension to 0.
        let maxWidth = x >= 0 && x < 1 ? 1.0 - clampedX : 1.0
        let maxHeight = y >= 0 && y < 1 ? 1.0 - clampedY : 1.0
        self.x = clampedX
        self.y = clampedY
        self.width = Self.round10(min(max(width, 0), maxWidth))
        self.height = Self.round10(min(max(height, 0), maxHeight))
    }

    /// Rounds to 10 decimal places to avoid IEEE 754 accumulation errors in
    /// operations like `1.0 − 0.8` that would otherwise differ from the
    /// nearest representable `Double` of the expected result.
    private static func round10(_ value: Double) -> Double {
        (value * 10_000_000_000).rounded() / 10_000_000_000
    }

    public static let zero = UnitRect(x: 0, y: 0, width: 0, height: 0)
}

/// Anchors annotation content (a stroke or text box) to a position inside the
/// engraved score's layout. Coordinates are relative to the system at
/// `systemIndex`, so anchors survive content reflow as long as the system
/// itself still exists.
public struct MusicalAnchor: Hashable, Sendable, Codable {
    public let systemIndex: Int
    public let normalizedFrame: UnitRect

    public init(systemIndex: Int, normalizedFrame: UnitRect) {
        self.systemIndex = max(0, systemIndex)
        self.normalizedFrame = normalizedFrame
    }
}
