@testable import Domain
import Testing

struct ScoreSourceKindLabelTests {
    @Test func labels() {
        #expect(ScoreSourceKind.museScore(majorVersion: 4).displayLabel == "MuseScore 4")
        #expect(ScoreSourceKind.musicXML.displayLabel == "MusicXML")
        #expect(ScoreSourceKind.midi.displayLabel == "MIDI")
        #expect(ScoreSourceKind.pdf.displayLabel == "PDF")
        #expect(ScoreSourceKind.unknown.displayLabel.isEmpty)
    }
}
