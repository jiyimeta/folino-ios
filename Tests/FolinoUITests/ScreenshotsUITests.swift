import ScreenshotKitUITest
import XCTest

@MainActor
final class ScreenshotsUITests: XCTestCase {
    private let languages = ["en", "ja", "ko", "zh-Hans", "zh-Hant"]

    override func setUp() {
        continueAfterFailure = false
    }

    func testCaptureReader() {
        captureScene(id: "01_Reader", languages: languages, in: self)
    }

    func testCapturePlaybackInspector() {
        captureScene(id: "02_PlaybackInspector", languages: languages, in: self)
    }

    func testCaptureVisualInspector() {
        captureScene(id: "03_VisualInspector", languages: languages, in: self)
    }

    func testCaptureABRepeat() {
        captureScene(id: "04_ABRepeat", languages: languages, in: self)
    }

    func testCaptureLibrary() {
        captureScene(id: "05_Library", languages: languages, in: self)
    }

    func testCapturePiP() {
        captureScene(id: "06_PiP", languages: languages, in: self)
    }

    func testCaptureAnnotation() {
        captureScene(id: "07_Annotation", languages: languages, in: self)
    }
}
