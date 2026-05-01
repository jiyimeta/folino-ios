import Foundation

/// A user-defined tag used to group score items. The color is stored as
/// `#RRGGBB` or `#RRGGBBAA` so Domain stays free of UI-framework types.
public struct Tag: Hashable, Sendable, Codable, Identifiable {
    public let id: TagID
    public var name: String
    public var colorHex: String

    public init(id: TagID = TagID(), name: String, colorHex: String) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
    }
}
