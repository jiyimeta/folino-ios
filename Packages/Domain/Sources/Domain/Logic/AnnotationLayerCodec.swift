import Foundation

/// The shared JSON codec for an annotation layer's persisted payload — the `{ drawings, textBoxes }` body both
/// platforms store (iOS in the GRDB `annotation_layers.payload` BLOB, Android in the Room `annotation_layers.payload`
/// column). The per-layer `id` / `scoreItemID` / `updatedAt` live in their own columns, so they are NOT part of this
/// body. Kept byte-shape-identical to the iOS `AnnotationLayerRecord.Body` (same field names, default `JSONEncoder`) so
/// existing stored blobs round-trip unchanged — no migration. `DrawingAnchor`'s neutral `InkStroke` FINK bytes ride
/// inside, base64-encoded by JSONEncoder, so a layer is byte-identical across platforms.
public enum AnnotationLayerCodec {
    private struct Body: Codable {
        var drawings: [DrawingAnchor]
        var textBoxes: [TextBoxAnchor]
    }

    /// Encode drawings + text boxes to the payload bytes. Empty `Data` only if encoding somehow fails (it does not for
    /// these value types).
    public static func encode(drawings: [DrawingAnchor], textBoxes: [TextBoxAnchor]) -> Data {
        (try? JSONEncoder().encode(Body(drawings: drawings, textBoxes: textBoxes))) ?? Data()
    }

    /// Decode payload bytes back to drawings + text boxes. `nil` when the bytes are not a valid layer body (garbage /
    /// truncated / unknown format) — the caller treats that as "no layer".
    public static func decode(_ data: Data) -> (drawings: [DrawingAnchor], textBoxes: [TextBoxAnchor])? {
        guard let body = try? JSONDecoder().decode(Body.self, from: data) else { return nil }
        return (body.drawings, body.textBoxes)
    }
}
