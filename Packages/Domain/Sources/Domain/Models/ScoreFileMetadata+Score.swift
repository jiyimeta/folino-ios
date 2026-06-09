import SheetMusicCore

extension ScoreSourceKind {
    /// Map a parsed score's source to the Domain credit-source kind. Shared by iOS (Infrastructure) and Android
    /// (FolinoLibraryJNI).
    public init(source: ScoreSource) {
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

extension ScoreFileMetadata {
    /// Build credit metadata from a parsed score's embedded metaTags (empty tags normalize to nil). Shared iOS/Android.
    public init(score: Score) {
        self.init(
            source: ScoreSourceKind(source: score.source),
            composer: score.metaTags["composer"].flatMap { $0.isEmpty ? nil : $0 },
            arranger: score.metaTags["arranger"].flatMap { $0.isEmpty ? nil : $0 },
            lyricist: score.metaTags["lyricist"].flatMap { $0.isEmpty ? nil : $0 },
            copyright: score.metaTags["copyright"].flatMap { $0.isEmpty ? nil : $0 },
        )
    }
}
