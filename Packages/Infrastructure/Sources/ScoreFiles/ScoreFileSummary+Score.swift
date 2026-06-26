import Domain
import Foundation
import SheetMusic

extension ScoreFileSummary {
    /// Derive a summary from a parsed `Score`. Best-effort — missing values fall back to safe defaults that make the
    /// summary usable as a library-row payload. The Reader plan will sharpen these as needed.
    init(score: Score) {
        // Title is no longer derived from score metadata — the importer uses the source filename instead, and rename is
        // a separate user action. Subtitle and composer are derived by the shared `ScorePresentation` so the iOS row
        // and the Android store stay in lockstep.
        let subtitle = ScorePresentation.subtitle(from: score)
        let composer = ScorePresentation.composer(from: score)
        let arranger = score.metaTags["arranger"]?.nonEmpty
        let lyricist = score.metaTags["lyricist"]?.nonEmpty
        let copyright = score.metaTags["copyright"]?.nonEmpty

        // Instrumentation: collect non-empty track names from parts; fall back to instrument long names when trackName
        // is nil.
        let names: [String] = score.parts.compactMap { part in
            if let track = part.trackName, !track.isEmpty { return track }
            if let track = part.instrument.trackName, !track.isEmpty { return track }
            if let long = part.instrument.longName, !long.isEmpty { return long }
            return nil
        }
        let instrumentationSummary = names.joined(separator: ", ")

        // Length: count measures on the first staff and assume 4/4. A precise port would inspect each measure's TimeSig
        // — out of scope for Plan #3, refined when the Reader plan needs it.
        let measureCount = score.allStaves.first?.staff.measures.count ?? 0
        let lengthBeats = measureCount * 4

        // Default tempo: not exposed by Score.metaTags reliably; v1 default matches MuseScore's own default of 120 bpm.
        let defaultTempoBpm = 120

        // Source kind: extract the MuseScore major version when the file originated from MuseScore. All other formats
        // (MusicXML, MIDI, PDF) yield nil, and PDF never reaches this path (pdfSummary handles it in the gateway).
        let museScoreMajorVersion: Int? = if case let .museScore(majorVersion) = ScoreSourceKind(source: score.source) {
            majorVersion
        } else {
            nil
        }

        self.init(
            title: nil,
            subtitle: subtitle,
            composer: composer,
            arranger: arranger,
            lyricist: lyricist,
            copyright: copyright,
            instrumentationSummary: instrumentationSummary,
            lengthBeats: lengthBeats,
            defaultTempoBpm: defaultTempoBpm,
            primaryKey: nil,
            museScoreMajorVersion: museScoreMajorVersion,
        )
    }
}
