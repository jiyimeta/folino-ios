import Foundation

/// The score file extensions folino accepts on import. Single source of truth shared by the iOS Share Extension
/// ingest gate and the Android share transport (`mscz, mscx, musicxml, mxl, xml, midi, mid`).
public enum ShareImportPolicy {
    public static let acceptedExtensions: Set = [
        "mscz", "mscx", "musicxml", "mxl", "xml", "midi", "mid",
    ]

    /// `true` when `filename`'s extension is in the allow-list (case-insensitive).
    public static func isAccepted(filename: String) -> Bool {
        acceptedExtensions.contains((filename as NSString).pathExtension.lowercased())
    }
}
