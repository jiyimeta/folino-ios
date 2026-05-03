import CoreGraphics
import Foundation

/// Per-score Reader display settings: engraved staff size and hidden-staff
/// set. Layout mode (vertical vs. page) is global and is NOT stored here —
/// the Reader feature reads it from `@AppStorage`.
public struct ReaderPreferences: Hashable, Sendable, Codable, Identifiable {
    public static let minStaffSize: CGFloat = 8
    public static let maxStaffSize: CGFloat = 28

    public let id: ReaderPreferencesID
    public let scoreItemID: ScoreItemID
    public var staffSize: CGFloat
    public var hiddenStaffIDs: Set<Int>

    public init(
        id: ReaderPreferencesID = ReaderPreferencesID(),
        scoreItemID: ScoreItemID,
        staffSize: CGFloat,
        hiddenStaffIDs: Set<Int>
    ) {
        self.id = id
        self.scoreItemID = scoreItemID
        self.staffSize = min(max(staffSize, Self.minStaffSize), Self.maxStaffSize)
        self.hiddenStaffIDs = hiddenStaffIDs
    }
}
