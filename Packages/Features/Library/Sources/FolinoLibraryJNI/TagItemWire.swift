import Wirelet

/// One tag-membership row (the score `scoreItemId` carries tag `tagId`).
@WireFormat
public struct TagItemWire: Equatable, Sendable {
    public var tagId: String
    public var scoreItemId: String

    public init(tagId: String, scoreItemId: String) {
        self.tagId = tagId
        self.scoreItemId = scoreItemId
    }
}
