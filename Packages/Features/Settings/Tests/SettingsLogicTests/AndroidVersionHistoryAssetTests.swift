import Domain
import Foundation
@testable import SettingsLogic
import Testing

/// Guards the hand-authored Android `VersionHistory.yml` asset: it must decode to at least one entry with the
/// shared loader, so a typo in the asset is caught in CI rather than shipping an empty "What's New" list.
struct AndroidVersionHistoryAssetTests {
    @Test func `android asset decodes to at least one entry`() throws {
        // <root>/Packages/Features/Settings/Tests/SettingsLogicTests/AndroidVersionHistoryAssetTests.swift
        // → delete 6 path components to reach the repository root.
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 6 {
            root.deleteLastPathComponent()
        }
        let assetURL = root.appendingPathComponent("Android/app/src/main/assets/VersionHistory.yml")

        let data = try Data(contentsOf: assetURL)
        let entries = try YAMLVersionHistoryLoader(data: data).load()
        #expect(!entries.isEmpty)
        // Every entry should carry at least one localized description string.
        #expect(entries.allSatisfy { !$0.descriptions.isEmpty })
    }
}
