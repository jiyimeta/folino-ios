// Sources/ImportExportAppGroup/SharedScorePaths.swift
import Foundation

/// The cross-app App Group folino shares with its sibling apps (VocalTuner). Distinct from `AppGroupIDs.identifier`,
/// which is folino's *private* group backing its own Share Extension.
public enum SharedAppGroupIDs {
    public static let identifier = "group.com.KeyNumber.shared"
}

/// Layout of the cross-app score hand-off area inside the shared App Group container.
///
/// A sibling app stages a score as `IncomingScores/<token>/{intent.json, files/<originalName>}` and then opens
/// `folino://open-score?token=<token>`; folino drains that token, imports the files, and scrubs the directory.
/// folino advertises that it speaks this protocol by stamping `folino/capabilities.json` on every launch — a sibling
/// that finds no stamp falls back to a plain share sheet.
///
/// Mirrors `AppGroupPaths` with two deliberate contract differences: the token is an opaque `String` rather than a
/// `UUID` (the contract only promises a string), and there are no playlist fields.
public enum SharedScorePaths {
    public static let incomingScoresDirname = "IncomingScores"
    public static let intentFilename = "intent.json"
    public static let filesDirname = "files"
    public static let capabilitiesDirname = "folino"
    public static let capabilitiesFilename = "capabilities.json"

    public static func container() -> URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedAppGroupIDs.identifier,
        )
    }

    /// Whether a token is safe to use as a path component. The token reaches us from a URL query string, so an
    /// unchecked value like `../../Soundfonts` would let a caller point the drain — and its unconditional scrub — at
    /// an arbitrary directory inside the shared container. Restricting it to the characters a UUID string uses is
    /// both sufficient for the contract and immune to traversal.
    public static func isValidToken(_ token: String) -> Bool {
        !token.isEmpty && token.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
        }
    }

    public static func incomingScoresURL(in container: URL) -> URL {
        container.appending(path: incomingScoresDirname, directoryHint: .isDirectory)
    }

    public static func tokenURL(token: String, in container: URL) -> URL {
        incomingScoresURL(in: container)
            .appending(path: token, directoryHint: .isDirectory)
    }

    public static func tokenIntentURL(token: String, in container: URL) -> URL {
        tokenURL(token: token, in: container)
            .appending(path: intentFilename, directoryHint: .notDirectory)
    }

    public static func tokenFilesURL(token: String, in container: URL) -> URL {
        tokenURL(token: token, in: container)
            .appending(path: filesDirname, directoryHint: .isDirectory)
    }

    public static func capabilitiesURL(in container: URL) -> URL {
        container
            .appending(path: capabilitiesDirname, directoryHint: .isDirectory)
            .appending(path: capabilitiesFilename, directoryHint: .notDirectory)
    }
}
