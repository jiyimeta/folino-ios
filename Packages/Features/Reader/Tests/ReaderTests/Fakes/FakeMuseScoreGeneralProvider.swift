import Domain
import Foundation
import Observation

@MainActor
@Observable
final class FakeMuseScoreGeneralProvider: MuseScoreGeneralProvider {
    var isOptedIn = true
    var downloadState: SoundfontDownloadState

    init(downloadState: SoundfontDownloadState = .idle) {
        self.downloadState = downloadState
    }

    var isDownloaded: Bool {
        if case .downloaded = downloadState { return true }
        return false
    }

    var museScoreGeneralFileURL: URL? {
        isDownloaded ? URL(filePath: "/tmp/MuseScore_General.sf2") : nil
    }

    nonisolated var museScoreGeneralFileURLSync: URL? {
        nil
    }

    nonisolated var isCurrentlyWiFi: Bool {
        true
    }

    var currentPreset: SoundfontPreset {
        isDownloaded ? .highQuality : .lightweight
    }

    func setOptedIn(_ value: Bool) {
        isOptedIn = value
    }

    func startDownloadIfNeeded() {}
    func startDownloadAllowingCellular() {}
    func cancelDownload() {}
    func deleteDownloaded() {}
}
