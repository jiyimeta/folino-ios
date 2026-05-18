#if DEBUG
import Domain
import Foundation
import Observation
import SheetMusicCore
import SheetMusicMSCX

// Preview-only fakes for Reader. Production code never instantiates these; they exist solely so `#Preview` blocks in
// this target can build a `ReaderViewModel` without depending on Infrastructure adapters or the test target's
// `@testable` fakes.
//
// Mirrors `Tests/ReaderTests/Fakes/` but is `internal` and #if DEBUG-guarded so it ships in debug builds (where
// previews live) and is stripped from release.

@MainActor
@Observable
final class PreviewFakeRepository: ScoreLibraryRepository {
    var scoreItems: [ScoreItem] = []
    var deletedScoreItems: [ScoreItem] = []
    var tags: [Tag] = []
    var playlists: [Playlist] = []

    func refresh() throws {}
    func saveScoreItem(_: ScoreItem) throws {}
    func deleteScoreItem(id _: Domain.ScoreItemID) throws {}
    func softDeleteScoreItem(id _: Domain.ScoreItemID) throws {}
    func restoreScoreItem(id _: Domain.ScoreItemID) throws {}
    func permanentlyDeleteScoreItem(id _: Domain.ScoreItemID) throws {}
    func pruneScoreItemsDeleted(before _: Date) throws {}
    func saveTag(_: Tag) throws {}
    func deleteTag(id _: TagID) throws {}
    func savePlaylist(_: Playlist) throws {}
    func deletePlaylist(id _: PlaylistID) throws {}
    func scoreItems(matchingContentHash _: String) throws -> [ScoreItem] {
        []
    }

    func loadReaderPreferences(for _: Domain.ScoreItemID) throws -> ReaderPreferences? {
        nil
    }

    func saveReaderPreferences(_: ReaderPreferences) throws {}

    static var sampleItem: ScoreItem {
        ScoreItem(
            title: "Preview",
            composer: "Preview",
            instrumentationSummary: "Violin",
            localFileName: "preview.mscx",
            contentHash: "preview",
            sizeBytes: 0,
            lengthBeats: 0,
            defaultTempoBpm: 120,
            primaryKey: nil,
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastOpenedAt: nil,
            tagIDs: [],
            isFavorite: false,
        )
    }
}

/// `ScoreLibraryRepository` fake that delegates every call to a held `PreviewFakeRepository` except
/// `loadReaderPreferences`, which returns a caller-provided `ReaderPreferences`. Use this in `#Preview` blocks that
/// need to exercise a non-default reader-preference state (e.g. a pre-seeded A–B loop) without touching the production
/// view-model API.
@MainActor
@Observable
final class PreviewSeededPreferencesRepository: ScoreLibraryRepository {
    private let base = PreviewFakeRepository()
    private let seededPreferences: ReaderPreferences

    init(seededPreferences: ReaderPreferences) {
        self.seededPreferences = seededPreferences
    }

    func loadReaderPreferences(for _: Domain.ScoreItemID) throws -> ReaderPreferences? {
        seededPreferences
    }

    /// Delegate every other method to `base`. (List them all so a future protocol addition fails to compile here,
    /// surfacing the gap.)
    var scoreItems: [ScoreItem] {
        base.scoreItems
    }

    var deletedScoreItems: [ScoreItem] {
        base.deletedScoreItems
    }

    var tags: [Tag] {
        base.tags
    }

    var playlists: [Playlist] {
        base.playlists
    }

    func refresh() throws {
        try base.refresh()
    }

    func saveScoreItem(_ item: ScoreItem) throws {
        try base.saveScoreItem(item)
    }

    func deleteScoreItem(id: Domain.ScoreItemID) throws {
        try base.deleteScoreItem(id: id)
    }

    func softDeleteScoreItem(id: Domain.ScoreItemID) throws {
        try base.softDeleteScoreItem(id: id)
    }

    func restoreScoreItem(id: Domain.ScoreItemID) throws {
        try base.restoreScoreItem(id: id)
    }

    func permanentlyDeleteScoreItem(id: Domain.ScoreItemID) throws {
        try base.permanentlyDeleteScoreItem(id: id)
    }

    func pruneScoreItemsDeleted(before cutoff: Date) throws {
        try base.pruneScoreItemsDeleted(before: cutoff)
    }

    func saveTag(_ tag: Tag) throws {
        try base.saveTag(tag)
    }

    func deleteTag(id: TagID) throws {
        try base.deleteTag(id: id)
    }

    func savePlaylist(_ playlist: Playlist) throws {
        try base.savePlaylist(playlist)
    }

    func deletePlaylist(id: PlaylistID) throws {
        try base.deletePlaylist(id: id)
    }

    func scoreItems(matchingContentHash hash: String) throws -> [ScoreItem] {
        try base.scoreItems(matchingContentHash: hash)
    }

    func saveReaderPreferences(_ prefs: ReaderPreferences) throws {
        try base.saveReaderPreferences(prefs)
    }
}

final class PreviewFakeGateway: ScoreFileGateway, @unchecked Sendable {
    let score: Score

    init(score: Score = Score(division: 480, parts: [], metaTags: [:])) {
        self.score = score
    }

    func detectFormat(fileName _: String) -> ScoreFormat? {
        .mscx
    }

    func loadFileMetadata(fileURL _: URL) throws -> ScoreFileSummary {
        ScoreFileSummary(
            title: "Preview",
            composer: nil,
            instrumentationSummary: "",
            lengthBeats: 0,
            defaultTempoBpm: 120,
            primaryKey: nil,
        )
    }

    func loadScore(fileURL _: URL) throws -> (score: Score, summary: ScoreFileSummary) {
        let summary = ScoreFileSummary(
            title: "Preview", composer: nil, instrumentationSummary: "",
            lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
        )
        return (score, summary)
    }

    func saveScore(_: Score, fileURL _: URL, format: ScoreFormat) throws {
        throw DomainError.unsupportedFormat(format.canonicalExtension)
    }
}

extension Instrument {
    /// Convenience for previews — a minimal instrument with an empty id.
    static var previewEmpty: Instrument {
        Instrument(id: "")
    }
}

/// Loads a real `.mscz` from `Resources/PreviewAssets/` if present. The file is intentionally not tracked in git —
/// developers drop a local score into that directory to iterate the page-mode layout against realistic content via
/// `mcp__xcode__RenderPreview`. Returns `nil` when the asset is missing or fails to parse, letting callers fall back to
/// a synthetic score.
enum PreviewBundledScore {
    static func nowIsTheTime() -> Score? {
        // SwiftPM's `.process(...)` flattens the resource directory structure, so the file sits at the bundle root
        // regardless of the on-disk `PreviewAssets/` subdirectory.
        guard let url = Bundle.module.url(
            forResource: "Now_is_the_time",
            withExtension: "mscz",
        ) else { return nil }
        return try? MSCZReader.parse(contentsOf: url)
    }
}

/// Hand-built score tall enough to scroll inside a typical iPad viewport. 36 measures of quarter notes wrapped across
/// many systems — the `VerticalScoreContainer` preview uses it to verify the initial scroll position lands at the top
/// of page 1, not somewhere in the middle.
enum PreviewSampleScore {
    static var tall: Score {
        let pitches: [(Int, Int)] = [
            (60, 14), (62, 16), (64, 18), (65, 13),
        ]
        let measures: [Measure] = (0 ..< 36).map { measureIndex in
            let chords: [VoiceElement] = pitches.map { pitch, tpc in
                .chord(Chord(
                    duration: .quarter,
                    notes: [Note(pitch: pitch, tpc: tpc)],
                ))
            }
            let prelude: [VoiceElement] = measureIndex == 0
                ? [
                    .clef(Clef(concertClefType: "G")),
                    .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                ]
                : []
            return Measure(voices: [Voice(elements: prelude + chords)])
        }
        let part = Part(
            id: "P0", trackName: "Treble", instrument: .previewEmpty,
            staves: [Staff(staffType: "stdNormal", group: "pitched", measures: measures)],
        )
        return Score(
            division: 480,
            parts: [part],
            metaTags: ["workTitle": "Scroll Position Test"],
        )
    }
}

#endif
