#if DEBUG
    import Domain
    import Foundation
    import Observation
    import SheetMusicCore

    // Preview-only fakes for Reader. Production code never instantiates these;
    // they exist solely so `#Preview` blocks in this target can build a
    // `ReaderViewModel` without depending on Infrastructure adapters or the
    // test target's `@testable` fakes.
    //
    // Mirrors `Tests/ReaderTests/Fakes/` but is `internal` and #if DEBUG-guarded
    // so it ships in debug builds (where previews live) and is stripped from
    // release.

    @MainActor
    @Observable
    final class PreviewFakeRepository: ScoreLibraryRepository {
        var scoreItems: [ScoreItem] = []
        var tags: [Tag] = []
        var playlists: [Playlist] = []

        func refresh() throws {}
        func saveScoreItem(_: ScoreItem) throws {}
        func deleteScoreItem(id _: Domain.ScoreItemID) throws {}
        func saveTag(_: Tag) throws {}
        func deleteTag(id _: TagID) throws {}
        func savePlaylist(_: Playlist) throws {}
        func deletePlaylist(id _: PlaylistID) throws {}
        func scoreItems(matchingContentHash _: String) throws -> [ScoreItem] { [] }

        func loadReaderPreferences(for _: Domain.ScoreItemID) throws -> ReaderPreferences? { nil }
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
                isFavorite: false
            )
        }
    }

    final class PreviewFakeGateway: ScoreFileGateway, @unchecked Sendable {
        let score: Score

        init(score: Score = Score(division: 480, parts: [], metaTags: [:])) {
            self.score = score
        }

        func detectFormat(fileName _: String) -> ScoreFormat? { .mscx }

        func loadFileMetadata(fileURL _: URL) throws -> ScoreFileSummary {
            ScoreFileSummary(
                title: "Preview",
                composer: nil,
                instrumentationSummary: "",
                lengthBeats: 0,
                defaultTempoBpm: 120,
                primaryKey: nil
            )
        }

        func loadScore(fileURL _: URL) throws -> (score: Score, summary: ScoreFileSummary) {
            let summary = ScoreFileSummary(
                title: "Preview", composer: nil, instrumentationSummary: "",
                lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil
            )
            return (score, summary)
        }

        func saveScore(_: Score, fileURL _: URL, format: ScoreFormat) throws {
            throw DomainError.unsupportedFormat(format.canonicalExtension)
        }
    }

    extension Instrument {
        /// Convenience for previews — a minimal instrument with an empty id.
        static var previewEmpty: Instrument { Instrument(id: "") }
    }

    /// Hand-built score tall enough to scroll inside a typical iPad viewport.
    /// 36 measures of quarter notes wrapped across many systems — the
    /// `VerticalScoreContainer` preview uses it to verify the initial scroll
    /// position lands at the top of page 1, not somewhere in the middle.
    enum PreviewSampleScore {
        static var tall: Score {
            let pitches: [(Int, Int)] = [
                (60, 14), (62, 16), (64, 18), (65, 13),
            ]
            let measures: [Measure] = (0 ..< 36).map { measureIndex in
                let chords: [VoiceElement] = pitches.map { pitch, tpc in
                    .chord(Chord(
                        duration: .quarter,
                        notes: [Note(pitch: pitch, tpc: tpc)]
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
                staves: [Staff(staffType: "stdNormal", group: "pitched", measures: measures)]
            )
            return Score(
                division: 480,
                parts: [part],
                metaTags: ["workTitle": "Scroll Position Test"]
            )
        }
    }

#endif
