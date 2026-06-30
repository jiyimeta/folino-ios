import Foundation

/// Stable error type for share-extension import failures, recorded as Crashlytics non-fatals. Grouping by a fixed
/// domain + per-class code keeps non-fatals aggregated by failure class rather than scattered by a raw localized
/// message. Carries no file path or score content, so the crash report stays free of user data.
enum ShareImportFailure: Error, CustomNSError {
    case fileNotFound
    case parseFailed
    case persistenceFailed
    case playlistCreateFailed

    static var errorDomain: String {
        "ImportExport.ShareImportFailure"
    }

    var errorCode: Int {
        switch self {
        case .fileNotFound: 1
        case .parseFailed: 2
        case .persistenceFailed: 3
        case .playlistCreateFailed: 4
        }
    }
}
