@testable import Domain
import Foundation
import Testing

struct ScoreFormatTests {
    @Test func `detects extensions case insensitively`() {
        #expect(ScoreFormat.detect(filename: "song.mscz") == .mscz)
        #expect(ScoreFormat.detect(filename: "song.MSCZ") == .mscz)
        #expect(ScoreFormat.detect(filename: "song.mscx") == .mscx)
        #expect(ScoreFormat.detect(filename: "song.musicxml") == .musicXML)
        #expect(ScoreFormat.detect(filename: "song.xml") == .musicXML)
        #expect(ScoreFormat.detect(filename: "song.mxl") == .mxl)
        #expect(ScoreFormat.detect(filename: "song.mid") == .midi)
        #expect(ScoreFormat.detect(filename: "song.midi") == .midi)
        #expect(ScoreFormat.detect(filename: "song.smf") == .midi)
    }

    @Test func `returns nil for PDF in V 1`() {
        #expect(ScoreFormat.detect(filename: "song.pdf") == nil)
        #expect(ScoreFormat.detect(filename: "song.PDF") == nil)
    }

    @Test func `returns nil for unknown extension`() {
        #expect(ScoreFormat.detect(filename: "song.txt") == nil)
        #expect(ScoreFormat.detect(filename: "song") == nil)
        #expect(ScoreFormat.detect(filename: "") == nil)
    }

    @Test func `handles paths with directories`() {
        #expect(ScoreFormat.detect(filename: "/Documents/Scores/song.mscz") == .mscz)
        #expect(ScoreFormat.detect(filename: "subdir/song.mscz") == .mscz)
    }

    @Test func `round trips through codable`() throws {
        for format in ScoreFormat.allCases {
            let data = try JSONEncoder().encode(format)
            let decoded = try JSONDecoder().decode(ScoreFormat.self, from: data)
            #expect(decoded == format)
        }
    }

    @Test func `canonical extension matches detect`() {
        for format in ScoreFormat.allCases {
            #expect(ScoreFormat.detect(filename: "song.\(format.canonicalExtension)") == format)
        }
    }
}
