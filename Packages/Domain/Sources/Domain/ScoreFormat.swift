import Foundation

/// File format folino can read and write. Each case represents a distinct on-disk encoding.
public enum ScoreFormat: String, Hashable, Sendable, Codable, CaseIterable {
    case mscx
    case mscz
    case musicXML
    case mxl
    case midi

    /// The default file extension folino writes when exporting this format.
    public var canonicalExtension: String {
        switch self {
        case .mscx: "mscx"
        case .mscz: "mscz"
        case .musicXML: "musicxml"
        case .mxl: "mxl"
        case .midi: "mid"
        }
    }

    /// Best-effort detection from a filename or path. Case-insensitive on the extension. Returns `nil` for `.pdf` in v1
    /// — PDF support is deferred to a later plan that introduces OCR.
    public static func detect(filename: String) -> ScoreFormat? {
        guard let dotIndex = filename.lastIndex(of: ".") else { return nil }
        let ext = filename[filename.index(after: dotIndex)...].lowercased()
        switch ext {
        case "mscx": return .mscx
        case "mscz": return .mscz
        case "musicxml", "xml": return .musicXML
        case "mxl": return .mxl
        case "mid", "midi", "smf": return .midi
        default: return nil
        }
    }
}
