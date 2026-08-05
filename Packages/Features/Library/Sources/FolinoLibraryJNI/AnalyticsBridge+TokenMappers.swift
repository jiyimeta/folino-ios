import Domain

/// Token mappers (case-name token -> Domain enum), split out of `AnalyticsBridge.swift` to keep that file under the
/// 400-line budget. They are `internal` rather than `private` only because they live in a separate file; nothing
/// outside this module can reach them.
///
/// Each resolves a Swift case-name token (what Kotlin passes) to the Domain enum, whose factory/`analyticsValue`
/// emits the stable wire string. Defaults are defensive: an unknown token degrades to the least-surprising case
/// rather than crashing the bridge. `RepeatMode` / `ReaderLayoutMode` / `AnalyticsActionMode` are String-raw with
/// rawValue == case name, so `init(rawValue:)` already accepts the token directly.
extension AnalyticsBridge {
    static func source(_ token: String) -> AnalyticsSource {
        switch token {
        case "scoreRowMenu": .scoreRowMenu
        case "bulkEdit": .bulkEdit
        case "readerOverlay": .readerOverlay
        case "scoreInfoSheet": .scoreInfoSheet
        case "recentlyOpened": .recentlyOpened
        case "favorites": .favorites
        case "playlist": .playlist
        case "tag": .tag
        case "searchResult": .searchResult
        case "libraryAll": .libraryAll
        default: .libraryAll
        }
    }

    static func mode(_ token: String) -> AnalyticsActionMode {
        AnalyticsActionMode(rawValue: token) ?? .single
    }

    static func shareFormat(_ token: String) -> ScoreShareFormat {
        switch token {
        case "museScoreV4": .museScoreV4
        case "museScoreV3": .museScoreV3
        case "pdf": .pdf
        case "midi": .midi
        case "audioM4A": .audioM4A
        default: .museScoreV4
        }
    }

    static func scoreFormat(_ token: String) -> ScoreFormat? {
        switch token {
        case "mscx": .mscx
        case "mscz": .mscz
        case "musicXML": .musicXML
        case "mxl": .mxl
        case "midi": .midi
        case "pdf": .pdf
        default: nil
        }
    }

    static func repeatMode(_ token: String) -> RepeatMode {
        RepeatMode(rawValue: token) ?? .off
    }

    static func layoutMode(_ token: String) -> ReaderLayoutMode {
        ReaderLayoutMode(rawValue: token) ?? .page
    }

    static func continuationMode(_ token: String) -> PlaylistContinuationMode {
        switch token {
        case "off": .off
        case "playThrough": .playThrough
        case "loopPlaylist": .loopPlaylist
        default: .off
        }
    }

    static func screen(_ token: String) -> AnalyticsScreen {
        switch token {
        case "library": .library
        case "reader": .reader
        case "scoreInfo": .scoreInfo
        case "settings": .settings
        case "recentlyDeleted": .recentlyDeleted
        case "playlistDetail": .playlistDetail
        case "tagDetail": .tagDetail
        default: .library
        }
    }
}
