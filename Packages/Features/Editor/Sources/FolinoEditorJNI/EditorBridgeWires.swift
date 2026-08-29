import Foundation
import Wirelet

/// An opaque byte frame crossing the Kotlin boundary in either direction.
///
/// Two things travel this way and neither is Kotlin's business: the intent bytes an op produced (encoded by ssm's
/// `EditIntentCodec`, decoded by ssm's `.so`), and the `ScoreItemID` a tap resolved to (encoded by ssm's
/// `ScoreItemIDCodec` on the far side, decoded here). Kotlin relays them; it never looks inside. That is the whole
/// point of crossing an intent rather than a command — see spec §4.2 and SP0's finding that a Kotlin-side encoder
/// was the wrong shape from the start.
///
/// A wrapper struct rather than a bare `Data` parameter because swift-wirelet's `InvokeArgClassifier` has no `Data`
/// case: a bare `Data` classifies as a `@WireFormat` type named `Data` and fails to generate. `Data` as a *field* of
/// a `@WireFormat` struct is supported and already in use (`DrawingAnchorWire.encodedDrawing`).
@WireFormat
public struct EditBytesWire {
    public var bytes: Data

    public init(bytes: Data) {
        self.bytes = bytes
    }
}
