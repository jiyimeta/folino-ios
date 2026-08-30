extension ScoreFormat {
    /// Stable wire value for analytics. Independent of `rawValue`/extension so refactors there don't shift analytics.
    public var analyticsValue: String {
        switch self {
        case .mscx: "mscx"
        case .mscz: "mscz"
        case .musicXML: "musicxml"
        case .mxl: "mxl"
        case .midi: "midi"
        case .pdf: "pdf"
        }
    }
}

extension ScoreItemSort {
    public var analyticsValue: String {
        switch self {
        case .dateAddedDesc: "date_added"
        case .titleAsc: "title"
        case .composerAsc: "composer"
        case .lastOpenedDesc: "last_opened"
        }
    }
}

extension ReaderLayoutMode {
    public var analyticsValue: String {
        switch self {
        case .vertical: "vertical"
        case .horizontal: "horizontal"
        case .page: "page"
        }
    }
}

extension RepeatMode {
    public var analyticsValue: String {
        switch self {
        case .off: "off"
        case .loopAll: "loop_all"
        case .abLoop: "ab_loop"
        }
    }
}

extension PlaylistContinuationMode {
    /// Stable wire value for analytics. Independent of `rawValue` so a future rename never shifts production data.
    public var analyticsValue: String {
        switch self {
        case .off: "off"
        case .playThrough: "play_through"
        case .loopPlaylist: "loop_playlist"
        }
    }
}

extension ScoreShareFormat {
    /// Stable share-method label for analytics. Distinguishes the two MuseScore wire versions even though both emit a
    /// `.mscz` container, so `share`'s `method` parameter stays unambiguous.
    public var analyticsValue: String {
        switch self {
        case .museScoreV4: "mscz_v4"
        case .museScoreV3: "mscz_v3"
        case .pdf: "pdf"
        case .midi: "midi"
        case .audioM4A: "m4a"
        case .annotatedPDF: "pdf_annotated"
        case .annotatedOriginalPDF: "pdf_original_annotated"
        }
    }
}
