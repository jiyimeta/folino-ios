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
