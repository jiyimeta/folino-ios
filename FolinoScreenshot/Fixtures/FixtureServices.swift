import Domain
import Foundation

/// Static fixture data + no-op service conformances used by the screenshot scenes so they can render real Folino
/// screens (`LibraryViewModel`, `ReaderRootScreen`) with fake, deterministic data. None of these touch disk, the
/// network, or a database. They live only in the `FolinoScreenshot` target — production composition never sees them.
///
/// `Score`, `Part`, `Staff`, `Measure`, `Voice`, `Chord`, `Instrument` are re-exported from `SheetMusicCore` through
/// `Domain`'s `@_exported import`, so `import Domain` is enough.
enum Fixture {
    /// A small non-empty score: one piano part, one staff, four measures of two quarter-note chords each. Built from
    /// public `SheetMusicCore` initializers (the same shape the Reader test fakes use). Enough to render a valid staff
    /// in the Reader chrome for a framed marketing shot.
    static let score: Score = {
        func measure() -> Measure {
            Measure(voices: [
                Voice(elements: [
                    .chord(Chord(duration: .quarter, notes: [])),
                    .chord(Chord(duration: .quarter, notes: [])),
                ]),
            ])
        }
        let staff = Staff(measures: (0 ..< 4).map { _ in measure() })
        let part = Part(id: "P1", instrument: Instrument(id: "piano"), staves: [staff])
        return Score(division: 480, parts: [part], metaTags: ["workTitle": "Now is the time!"])
    }()

    /// Build a library row with realistic-looking metadata. Only the fields the list/Reader read need to be meaningful;
    /// the rest are plausible placeholders.
    static func scoreItem(title: String, composer: String, favorite: Bool = false) -> ScoreItem {
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
            lastOpenedAt: nil,
            tagIDs: [],
            isFavorite: favorite,
            deletedAt: nil,
        )
    }

    /// Three realistic library items for a populated list shot.
    static let items: [ScoreItem] = [
        scoreItem(title: "Now is the time!", composer: "Kiichi", favorite: true),
        scoreItem(title: "Prelude in C", composer: "Bach"),
        scoreItem(title: "Gymnopédie No.1", composer: "Satie"),
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
