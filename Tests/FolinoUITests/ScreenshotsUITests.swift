import ScreenshotKitUITest
import XCTest

@MainActor
final class ScreenshotsUITests: XCTestCase {
    private let languages = ["en", "ja", "ko", "zh-Hans", "zh-Hant"]

    override func setUp() {
        continueAfterFailure = false
    }

    func testCaptureLibrary() {
        captureScene(id: "01_Library", languages: languages, in: self)
    }

    func testCaptureReader() {
        captureScene(id: "02_Reader", languages: languages, in: self)
    }

    func testCaptureHorizontal() {
        captureScene(id: "06_Horizontal", languages: languages, in: self)
    }
}
