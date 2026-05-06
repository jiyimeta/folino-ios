import Domain
import Foundation
@testable import Settings
import SwiftUI
import Testing

@Suite @MainActor
struct SettingsSheetTests {
    @Test func sheetConstructsWithStubLicenseContent() {
        let sheet = SettingsSheet { Text("License placeholder") }
        // The view is a value; if it constructs, this test passes.
        _ = sheet.body
    }

    @Test func sheetConstructsWithStubResolver() {
        let sheet = SettingsSheet(soundfontResolver: StubSoundfontResolver()) {
            Text("License placeholder")
        }
        _ = sheet.body
    }
}

private struct StubSoundfontResolver: SoundfontResolver {
    func resolveSoundfont(bank _: Int, program _: Int) throws -> URL {
        URL(fileURLWithPath: "/dev/null")
    }

    func cachedPatches() throws -> [SoundfontPatch] { [] }
    func totalCacheSizeBytes() throws -> Int64 { 0 }
    func deletePatch(bank _: Int, program _: Int) throws {}
    func clearCache() throws {}
}
