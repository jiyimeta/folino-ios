import Domain
import Foundation
import Observation
@testable import Settings
import SwiftUI
import Testing
import UtilityCore

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

    @Test func `sheet constructs with an injected crash reporter`() {
        let sheet = SettingsSheet(crashReporter: SpyCrashReporter()) { Text("License placeholder") }
        _ = sheet.body
    }
}

/// Test double for the crash-reporting injection seam. The privacy toggle's `onChange` side effect is verified
/// end to end (a SwiftUI `@AppStorage` `onChange` cannot be driven from a value-level unit test); this spy pins the
/// `init(crashReporter:)` parameter.
private final class SpyCrashReporter: CrashReporter, @unchecked Sendable {
    private(set) var collectionEnabledCalls: [Bool] = []
    func setCollectionEnabled(_ enabled: Bool) {
        collectionEnabledCalls.append(enabled)
    }

    func log(_: String) {}
    func record(error _: Error) {}
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
