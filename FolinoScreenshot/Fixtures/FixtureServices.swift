import Domain
import Foundation
import SheetMusicMSCX

/// Static fixture data + no-op service conformances used by the screenshot scenes so they can render real Folino
/// screens (`LibraryViewModel`, `ReaderRootScreen`) with fake, deterministic data. None of these touch disk, the
/// network, or a database. They live only in the `FolinoScreenshot` target — production composition never sees them.
///
/// `Score`, `Part`, `Staff`, `Measure`, `Voice`, `Chord`, `Instrument` are re-exported from `SheetMusicCore` through
/// `Domain`'s `@_exported import`, so `import Domain` is enough.
enum Fixture {
    /// The score rendered in the framed marketing shots. Parses the bundled real `Now_is_the_time.mscz` (a
    /// multi-measure score with actual notes) so the Reader / Horizontal scenes show a realistic page. Falls back to
    /// `syntheticScore` if the file is missing or parsing throws.
    static let score: Score = {
        if let url = Bundle.main.url(forResource: "Now_is_the_time", withExtension: "mscz"),
           let parsed = try? MSCZReader.parse(contentsOf: url)
        {
            return parsed
        }
        return syntheticScore
    }()

    /// A small non-empty score: one piano part, one staff, four measures of two quarter-note chords each, carrying a
    /// simple ascending C-major melody (C D E F | G A B C) so the staff renders real noteheads in the framed marketing
    /// shot. Built from public `SheetMusicCore` initializers (the same shape the Reader test fakes use). Used as the
    /// fallback when the bundled real score can't be parsed.
    static let syntheticScore: Score = {
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
    /// the rest are plausible placeholders. `composer` is optional — pass `nil` for "no composer" (the `ScoreItem`
    /// model stores `composer` as `String?`, and `ScoreRow` shows nothing when it's nil).
    static func scoreItem(
        title: String,
        composer: String? = nil,
        favorite: Bool = false,
        lastOpenedAt: Date? = nil,
        tagIDs: Set<TagID> = [],
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
            tagIDs: tagIDs,
            isFavorite: favorite,
            deletedAt: nil,
        )
    }

    /// A single localized tag ("練習中" / "Practicing") applied to the second fixture item. The `name` is resolved at
    /// access time via `String(localized:)` against `ScreenshotStrings`, so it reflects the per-launch locale (each
    /// screenshot capture launches in its target locale). Declared `static let` but the `name` computation runs once
    /// per process after launch, which is when the active locale is already set.
    static let practicingTag = Tag(
        name: String(
            localized: LocalizedStringResource(
                "fixture.tag.practicing",
                table: "ScreenshotStrings",
                bundle: .forClass(FixtureStringsAnchor.self),
            ),
        ),
        colorHex: "#FF9500",
    )

    /// Three realistic library items for a populated list shot. The middle item ("アタタメマスカ") carries the
    /// `practicingTag` and has no composer; the others have no tags.
    static let items: [ScoreItem] = [
        scoreItem(
            title: "Now is the time!",
            composer: "Kiichi",
            favorite: true,
            lastOpenedAt: Date(timeIntervalSince1970: 1_717_900_000),
        ),
        scoreItem(
            title: "アタタメマスカ",
            composer: nil,
            lastOpenedAt: Date(timeIntervalSince1970: 1_717_800_000),
            tagIDs: [practicingTag.id],
        ),
        scoreItem(
            title: "Looks Good To Me",
            composer: "Kiichi",
            lastOpenedAt: Date(timeIntervalSince1970: 1_717_700_000),
        ),
    ]

    /// Two user-created playlists, each containing all three fixture items (by their generated `ScoreItemID`s). Names
    /// are literal user strings (not localized).
    static let playlists: [Playlist] = {
        let allIDs = items.map(\.id)
        return [
            Playlist(name: "余白計画", orderedScoreItemIDs: allIDs, createdAt: Date(timeIntervalSince1970: 1_717_600_000)),
            Playlist(name: "ぴのグリ", orderedScoreItemIDs: allIDs, createdAt: Date(timeIntervalSince1970: 1_717_500_000)),
        ]
    }()
}

/// Marker class to resolve the bundle hosting `ScreenshotStrings.xcstrings` from the fixture layer (mirrors the
/// `ScreenshotStringsAnchor` in `LibraryScene`). `.forClass` anchors lookup to this app target's bundle.
private final class FixtureStringsAnchor {}

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
