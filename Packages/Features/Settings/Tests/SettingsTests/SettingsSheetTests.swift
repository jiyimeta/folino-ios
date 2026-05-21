import Domain
import Foundation
import Observation
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
