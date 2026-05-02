import Foundation
import SheetMusic
import Testing

enum Fixtures {
    /// Loads `minimal.mscx` bytes from the test bundle.
    static func minimalMSCXData() throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "minimal", withExtension: "mscx"))
        return try Data(contentsOf: url)
    }

    /// Synthesizes minimal `.mscz` bytes by packaging the bundled `.mscx`
    /// through `swift-sheet-music`'s MSCZ writer. No GPL fixture data.
    static func minimalMSCZData() throws -> Data {
        let mscx = try minimalMSCXData()
        return try SheetMusic.saveMSCZ(mscxData: mscx)
    }

    /// Synthesizes minimal `.mid` bytes by parsing the `.mscx` fixture and
    /// rendering it through `SheetMusic.exportMIDI`.
    static func minimalMIDIData() throws -> Data {
        let score = try SheetMusic.loadScore(mscxData: minimalMSCXData())
        return try SheetMusic.exportMIDI(score: score)
    }

    /// Writes the bytes to a tmp URL with the given extension, returning the URL.
    static func writeToTempFile(_ data: Data, ext: String, in directory: URL) throws -> URL {
        let url = directory.appending(path: "fixture-\(UUID().uuidString).\(ext)")
        try data.write(to: url)
        return url
    }
}
