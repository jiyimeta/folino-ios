import Domain
import Foundation
import ScoreFiles
import Testing

/// Runs every PDF under `FOLINO_OMR_SMOKE_DIR` through the live parser and prints what came back, so a
/// scanned-PDF import can be measured on the simulator without installing the app. Off unless the directory
/// is set (`TEST_RUNNER_FOLINO_OMR_SMOKE_DIR=… xcodebuild test …`), so the regular suite carries nothing.
@Suite(.enabled(if: OMRSmokeEnvironment.directory != nil))
struct LivePDFPlaybackParserOMRSmokeTests {
    @Test func `every PDF in the smoke directory parses into a playable score`() async throws {
        let directory = try #require(OMRSmokeEnvironment.directory)
        let files = try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "pdf" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        #expect(!files.isEmpty, "no PDFs under \(directory.path)")

        let parser = LivePDFPlaybackParser()
        for file in files {
            let clock = ContinuousClock()
            let start = clock.now
            let result = try await parser.parse(pdfURL: file)
            let elapsed = clock.now - start
            let score = result.score
            let measures = score.parts.first?.staves.first?.measures.count ?? 0
            print(
                "OMR-SMOKE \(file.lastPathComponent): playable=\(score.playableElementCount) "
                    + "parts=\(score.parts.count) measures=\(measures) diagnostics=\(result.diagnostics.count) "
                    + "elapsed=\(elapsed)",
            )
            for diagnostic in result.diagnostics {
                print("OMR-SMOKE   [\(diagnostic.severity)] \(diagnostic.location): \(diagnostic.message)")
            }
            #expect(score.hasPlayableContent, "\(file.lastPathComponent) yielded nothing playable")
        }
    }
}

enum OMRSmokeEnvironment {
    static var directory: URL? {
        ProcessInfo.processInfo.environment["FOLINO_OMR_SMOKE_DIR"].map { URL(fileURLWithPath: $0) }
    }
}
