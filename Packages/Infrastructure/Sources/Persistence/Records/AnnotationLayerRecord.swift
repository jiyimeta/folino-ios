import Domain
import Foundation
import GRDB

/// Row mirror for the `annotation_layers` table. The drawings + text boxes are JSON-encoded into the `payload` BLOB
/// column (the opaque PKDrawing blobs ride inside the `DrawingAnchor`s, base64-encoded by JSONEncoder). `id`,
/// `score_item_id`, and `updated_at` are columns so they can be keyed/queried without decoding the payload.
struct AnnotationLayerRecord: FetchableRecord, PersistableRecord, Codable {
    static let databaseTableName = "annotation_layers"

    var id: String
    var scoreItemId: String
    var updatedAt: Double
    var payload: Data

    enum CodingKeys: String, CodingKey {
        case id
        case scoreItemId = "score_item_id"
        case updatedAt = "updated_at"
        case payload
    }

    /// The JSON body stored in `payload`. `updatedAt`/ids live in their own columns, so the body is just the content.
    private struct Body: Codable {
        var drawings: [DrawingAnchor]
        var textBoxes: [TextBoxAnchor]
    }

    /// Raw-bytes initializer for the `AnnotationBlobStore` write path: the payload is stored verbatim (the shared
    /// `AnnotationSaveCoordinator` already encoded it with `AnnotationLayerCodec`, byte-identical to `Body`), so there
    /// is no domain round-trip. Spelled out because the `init(domain:)` below suppresses the memberwise initializer.
    init(id: String, scoreItemId: String, updatedAt: Double, payload: Data) {
        self.id = id
        self.scoreItemId = scoreItemId
        self.updatedAt = updatedAt
        self.payload = payload
    }

    init(domain layer: AnnotationLayer) throws {
        id = layer.id.rawValue.uuidString
        scoreItemId = layer.scoreItemID.rawValue.uuidString
        updatedAt = layer.updatedAt.timeIntervalSince1970
        let body = Body(drawings: layer.drawings, textBoxes: layer.textBoxes)
        do {
            payload = try JSONEncoder().encode(body)
        } catch {
            throw DomainError.persistenceFailed(reason: "annotation_layers payload encode failed: \(error)")
        }
    }

    func toDomain() throws -> AnnotationLayer {
        guard let idUUID = UUID(uuidString: id) else {
            throw DomainError.persistenceFailed(reason: "annotation_layers.id is not a valid UUID: \(id)")
        }
        guard let scoreUUID = UUID(uuidString: scoreItemId) else {
            throw DomainError.persistenceFailed(
                reason: "annotation_layers.score_item_id is not a valid UUID: \(scoreItemId)",
            )
        }
        let body: Body
        do {
            body = try JSONDecoder().decode(Body.self, from: payload)
        } catch {
            throw DomainError.persistenceFailed(reason: "annotation_layers payload decode failed: \(error)")
        }
        return AnnotationLayer(
            id: AnnotationLayerID(rawValue: idUUID),
            scoreItemID: ScoreItemID(rawValue: scoreUUID),
            drawings: body.drawings,
            textBoxes: body.textBoxes,
            updatedAt: Date(timeIntervalSince1970: updatedAt),
        )
    }
}
