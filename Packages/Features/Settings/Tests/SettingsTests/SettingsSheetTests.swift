import Domain
import Foundation
@testable import Settings
import SwiftUI
import Testing

@MainActor
struct SettingsSheetTests {
    @Test func `sheet constructs with stub license content`() {
        let sheet = SettingsSheet { Text("License placeholder") }
        // The view is a value; if it constructs, this test passes.
        _ = sheet.body
    }

    @Test func `sheet constructs with stub provider`() {
        let sheet = SettingsSheet(provider: StubProvider()) {
            Text("License placeholder")
        }
        _ = sheet.body
    }
}

private struct StubProvider: MuseScoreGeneralProvider {
    var isOptedIn: Bool {
        true
    }

    var isDownloaded: Bool {
        false
    }

    var museScoreGeneralFileURL: URL? {
        nil
    }

    var museScoreGeneralFileURLSync: URL? {
        nil
    }

    var currentPreset: SoundfontPreset {
        .lightweight
    }

    func setOptedIn(_: Bool) {}
    func downloadStateStream() -> AsyncStream<SoundfontDownloadState> {
        AsyncStream { _ in }
    }

    func startDownloadIfNeeded() {}
    func startDownloadAllowingCellular() {}
    func cancelDownload() {}
    func deleteDownloaded() {}
}
