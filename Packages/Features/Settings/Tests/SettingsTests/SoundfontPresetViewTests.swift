import Domain
import Foundation
import Observation
@testable import Settings
import Testing

@MainActor
struct SoundfontPresetRowTests {
    @Test func `row instantiates with a stub provider`() {
        let row = SoundfontPresetRow(provider: StubProvider())
        _ = row.body
    }
}

@MainActor
@Observable
private final class StubProvider: MuseScoreGeneralProvider {
    var isOptedIn = true
    var downloadState: SoundfontDownloadState = .idle

    var isDownloaded: Bool {
        false
    }

    var museScoreGeneralFileURL: URL? {
        nil
    }

    nonisolated var museScoreGeneralFileURLSync: URL? {
        nil
    }

    nonisolated var isCurrentlyWiFi: Bool {
        true
    }

    var currentPreset: SoundfontPreset {
        .lightweight
    }

    func setOptedIn(_: Bool) {}
    func startDownloadIfNeeded() {}
    func startDownloadAllowingCellular() {}
    func cancelDownload() {}
    func deleteDownloaded() {}
}
