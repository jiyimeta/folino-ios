import Domain
import Foundation
import SheetMusic

/// Live `ScoreShareService` backed by `swift-sheet-music`. Companion to
/// `LiveScoreFileGateway` in the same module.
public struct LiveScoreShareService: ScoreShareService {
    private let scoresDirectory: URL
    private let shareTempDirectory: URL
    private let gateway: any ScoreFileGateway

    public init(
        scoresDirectory: URL,
        shareTempDirectory: URL,
        gateway: any ScoreFileGateway
    ) {
        self.scoresDirectory = scoresDirectory
        self.shareTempDirectory = shareTempDirectory
        self.gateway = gateway
    }

    /// Internal for tests. Replaces filesystem-hostile characters,
    /// trims to ≤100 chars, falls back to `"score"` if empty.
    static func sanitize(title: String) -> String {
        let bad: Set<Character> = ["/", ":", "\\", "\u{0000}"]
        let cleaned = String(title.map { bad.contains($0) ? "_" : $0 })
        let stripped = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "_ "))
        let candidate = stripped.isEmpty ? "score" : stripped
        return String(candidate.prefix(100))
    }

    public func availableFormats(for _: ScoreItem) -> [ScoreShareFormat] {
        // TODO: re-evaluate when LiveScoreFileGateway gains MIDI parsing —
        // PDF/MIDI for a `.midi` item would fail with `scoreParseFailed`
        // until then. Imports of `.midi` are currently blocked.
        [.sourceFormat, .pdf, .midi]
    }

    public func resolvedSourceFormat(for item: ScoreItem) -> ScoreFormat {
        // localFileName follows the import-time invariant
        // "<id>.<canonical-extension>", so detect() is total here.
        guard let format = ScoreFormat.detect(filename: item.localFileName) else {
            return .mscz
        }
        switch format {
        case .mscx, .mscz: return .mscz
        case .musicXML: return .musicXML
        case .mxl: return .mxl
        case .midi: return .midi
        }
    }

    public func prepareShare(
        item _: ScoreItem,
        format _: ScoreShareFormat
    ) async throws -> URL {
        // Tasks 4-7 will replace this stub with real format conversion.
        // `await Task.yield()` keeps the function genuinely async so the
        // ScoreShareService protocol conformance compiles cleanly.
        await Task.yield()
        throw DomainError.unsupportedFormat("share")
    }
}
