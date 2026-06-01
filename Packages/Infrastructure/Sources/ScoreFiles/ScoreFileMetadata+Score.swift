import Domain
import Foundation
import SheetMusic

extension ScoreFileMetadata {
    /// Build the Domain-side read-only metadata from a parsed `Score`. Maps `Score.source` into the engine-free
    /// `ScoreSourceKind` and pulls the credit metaTags (empty strings normalized to nil via `nonEmpty`).
    init(score: Score) {
        self.init(
            source: ScoreSourceKind(source: score.source),
            composer: score.metaTags["composer"]?.nonEmpty,
            arranger: score.metaTags["arranger"]?.nonEmpty,
            lyricist: score.metaTags["lyricist"]?.nonEmpty,
            copyright: score.metaTags["copyright"]?.nonEmpty,
        )
    }
}

extension ScoreSourceKind {
    init(source: ScoreSource) {
        switch source {
        case let .museScore(version):
            switch version {
            case .v2: self = .museScore(majorVersion: 2)
            case .v3: self = .museScore(majorVersion: 3)
            case .v4: self = .museScore(majorVersion: 4)
            }
        case .musicXML: self = .musicXML
        case .midi: self = .midi
        case .pdf: self = .pdf
        case .unknown: self = .unknown
        }
    }
}
