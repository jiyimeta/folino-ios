import Foundation

/// File format Folino can read and write. Each case represents a distinct on-disk encoding.
public enum ScoreFormat: String, Hashable, Sendable, Codable, CaseIterable {
    case mscx
    case mscz
    case musicXML
    case mxl
    case midi
    case pdf

    /// The default file extension Folino writes when exporting this format.
    public var canonicalExtension: String {
        switch self {
        case .mscx: "mscx"
        case .mscz: "mscz"
        case .musicXML: "musicxml"
        case .mxl: "mxl"
        case .midi: "mid"
        case .pdf: "pdf"
        }
    }

    /// Best-effort detection from a filename or path. Case-insensitive on the extension.
    public static func detect(filename: String) -> ScoreFormat? {
        guard let dotIndex = filename.lastIndex(of: ".") else { return nil }
        let ext = filename[filename.index(after: dotIndex)...].lowercased()
        switch ext {
        case "mscx": return .mscx
        case "mscz": return .mscz
        case "musicxml", "xml": return .musicXML
        case "mxl": return .mxl
        case "mid", "midi", "smf": return .midi
        case "pdf": return .pdf
        default: return nil
        }
    }
}
