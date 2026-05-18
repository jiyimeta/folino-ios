import Domain
import Foundation
import SheetMusic

extension ScoreFileSummary {
    /// Derive a summary from a parsed `Score`. Best-effort — missing values fall back to safe defaults that make the
    /// summary usable as a library-row payload. The Reader plan will sharpen these as needed.
    init(score: Score) {
        // Title is no longer derived from score metadata — the importer uses the source filename instead, and rename is
        // a separate user action. Subtitle still comes from the title frame (`<VBox>`/`<Text>` with
        // `<style>Subtitle</style>`); composer from the workTitle-adjacent `composer` metaTag.
        let frameTexts = score.titleFrame?.texts ?? []
        let subtitle = frameTexts.first(where: { $0.style == .subtitle })?.text.nonEmpty
        let composer = score.metaTags["composer"]?.nonEmpty

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

        self.init(
            title: nil,
            subtitle: subtitle,
            composer: composer,
            instrumentationSummary: instrumentationSummary,
            lengthBeats: lengthBeats,
            defaultTempoBpm: defaultTempoBpm,
            primaryKey: nil,
        )
    }
}

extension String {
    fileprivate var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
