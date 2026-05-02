import Foundation

/// Creates a unique temp directory under `NSTemporaryDirectory()` and removes
/// it when destroyed. Use as `let tmp = try TempDirectory()` in a test —
/// the directory's URL is `tmp.url`.
final class TempDirectory {
    let url: URL

    init() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        url = base.appending(path: "folino-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
