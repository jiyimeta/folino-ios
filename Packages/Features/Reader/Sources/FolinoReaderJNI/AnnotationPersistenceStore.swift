import Foundation
import WireletProvided

/// Per-score annotation-layer persistence, *implemented in Kotlin* (Room `annotation_layers` table) and injected into
/// `AnnotationSaveBridge` over JNI. Rule-free blob I/O only — all policy (debounce / empty→delete / layer assembly)
/// lives in the shared `Domain.AnnotationSaveCoordinator`, in lockstep with iOS.
///
/// `Data` crosses the wire as a length-delimited `@WireFormat` value (Wirelet's `Data` conformance), so the payload
/// bytes are byte-identical to what iOS's GRDB `annotation_layers.payload` BLOB stores.
@WireletProvided
public protocol AnnotationPersistenceStore {
    /// The stored payload bytes for `scoreId`, or empty `Data` when no layer has been saved yet.
    func loadBytes(scoreId: String) -> Data
    /// Insert or replace the stored payload bytes for `scoreId`, recording the layer's updated-at (epoch millis).
    func saveBytes(scoreId: String, updatedAtMillis: Int64, bytes: Data)
    /// Remove the score's annotation layer entirely (used when the coordinator's empty→delete policy fires).
    func delete(scoreId: String)
}
