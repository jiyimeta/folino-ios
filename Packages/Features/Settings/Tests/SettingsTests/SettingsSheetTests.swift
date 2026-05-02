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
}
