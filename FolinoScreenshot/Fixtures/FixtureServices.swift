import Domain
import Foundation

/// Static fixture data + no-op service conformances used by the screenshot scenes so they can render real Folino
/// screens (`LibraryViewModel`, `ReaderRootScreen`) with fake, deterministic data. None of these touch disk, the
/// network, or a database. They live only in the `FolinoScreenshot` target — production composition never sees them.
///
/// `Score`, `Part`, `Staff`, `Measure`, `Voice`, `Chord`, `Instrument` are re-exported from `SheetMusicCore` through
/// `Domain`'s `@_exported import`, so `import Domain` is enough.
enum Fixture {
    /// A small non-empty score: one piano part, one staff, four measures of two quarter-note chords each, carrying a
    /// simple ascending C-major melody (C D E F | G A B C) so the staff renders real noteheads in the framed marketing
    /// shot. Built from public `SheetMusicCore` initializers (the same shape the Reader test fakes use).
    static let score: Score = {
        /// A quarter-note chord with a single natural note in octave 4 (middle-C octave). Falls back to middle C
        /// (pitch 60, tpc 14) if a letter is somehow unmapped — all call sites below pass valid `c d e f g a b`.
        func note(_ letter: Character) -> Chord {
            let spelling = NoteInputKeyMap.pitch(forLetter: letter, octave: 4) ?? (pitch: 60, tpc: 14)
            return Chord(duration: .quarter, notes: [Note(pitch: spelling.pitch, tpc: spelling.tpc)])
        }
        func measure(_ first: Character, _ second: Character) -> Measure {
            Measure(voices: [
                Voice(elements: [.chord(note(first)), .chord(note(second))]),
            ])
        }
        let staff = Staff(measures: [
            measure("c", "d"),
            measure("e", "f"),
            measure("g", "a"),
            measure("b", "c"),
        ])
        let part = Part(id: "P1", instrument: Instrument(id: "piano"), staves: [staff])
        return Score(division: 480, parts: [part], metaTags: ["workTitle": "Now is the time!"])
    }()

    /// Build a library row with realistic-looking metadata. Only the fields the list/Reader read need to be meaningful;
    /// the rest are plausible placeholders.
    static func scoreItem(
        title: String,
        composer: String,
        favorite: Bool = false,
        lastOpenedAt: Date? = nil,
    ) -> ScoreItem {
        let id = ScoreItemID()
        return ScoreItem(
            id: id,
            title: title,
            subtitle: nil,
            composer: composer,
            arranger: nil,
            lyricist: nil,
            copyright: nil,
            instrumentationSummary: "Piano",
            localFileName: "\(id).mscz",
            contentHash: "fixture-\(title.lowercased())",
            sizeBytes: 24576,
            lengthBeats: 128,
            defaultTempoBpm: 120,
            primaryKey: "C",
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastOpenedAt: lastOpenedAt,
            tagIDs: [],
            isFavorite: favorite,
            deletedAt: nil,
        )
    }

    /// Three realistic library items for a populated list shot.
    static let items: [ScoreItem] = [
        scoreItem(
            title: "Now is the time!",
            composer: "Kiichi",
            favorite: true,
            lastOpenedAt: Date(timeIntervalSince1970: 1_717_900_000),
        ),
        scoreItem(
            title: "Prelude in C",
            composer: "Bach",
            lastOpenedAt: Date(timeIntervalSince1970: 1_717_800_000),
        ),
        scoreItem(
            title: "Gymnopédie No.1",
            composer: "Satie",
            lastOpenedAt: Date(timeIntervalSince1970: 1_717_700_000),
        ),
    ]
}

/// No-op `ScoreFileGateway`: every load returns `Fixture.score`; writes throw `unsupportedFormat` (matching production
/// v1 behavior — there is no Score serializer yet).
struct FixtureGateway: ScoreFileGateway {
    func detectFormat(fileName: String) -> ScoreFormat? {
        .mscx
    }

    func loadFileMetadata(fileURL: URL) throws -> ScoreFileSummary {
        summary
    }

    func loadScore(fileURL: URL) throws -> (score: Score, summary: ScoreFileSummary) {
        (score: Fixture.score, summary: summary)
    }

    func saveScore(_ score: Score, fileURL: URL, format: ScoreFormat) throws {
        throw DomainError.unsupportedFormat(format.canonicalExtension)
    }

    private var summary: ScoreFileSummary {
        ScoreFileSummary(
            title: "Now is the time!",
            composer: "Kiichi",
            instrumentationSummary: "Piano",
            lengthBeats: 128,
            defaultTempoBpm: 120,
            primaryKey: "C",
        )
    }
}

/// No-op `ScoreFileImporter`: import flows are never exercised in screenshot scenes, so both stages throw.
struct FixtureImporter: ScoreFileImporter {
    func prepareImport(sourceURL: URL) throws -> ImportPlan {
        throw DomainError.unsupportedFormat("fixture")
    }

    func commitImport(_ plan: ImportPlan, decision: ImportDecision) throws -> ScoreItem {
        throw DomainError.unsupportedFormat("fixture")
    }
}

/// No-op `ScoreShareService`: no formats offered, share preparation never invoked.
struct FixtureShareService: ScoreShareService {
    func availableFormats(for item: ScoreItem) -> [ScoreShareFormatOption] {
        []
    }

    func prepareShare(item: ScoreItem, format: ScoreShareFormat) throws -> URL {
        throw DomainError.unsupportedFormat(format.canonicalExtension)
    }
}

/// No-op `ScoreMetadataReading`: reports a plausible MuseScore-v4 source with the fixture credits.
struct FixtureMetadataReader: ScoreMetadataReading {
    func readMetadata(for item: ScoreItem) throws -> ScoreFileMetadata {
        ScoreFileMetadata(
            source: .museScore(majorVersion: 4),
            composer: item.composer,
            arranger: nil,
            lyricist: nil,
            copyright: nil,
        )
    }
}
