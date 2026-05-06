import Domain
import Foundation
import SheetMusic

extension ScoreFileSummary {
    /// Derive a summary from a parsed `Score`. Best-effort — missing values
    /// fall back to safe defaults that make the summary usable as a library-
    /// row payload. The Reader plan will sharpen these as needed.
    init(score: Score) {
        // Title / subtitle: prefer the first matching text in the title
        // frame (MuseScore's `<VBox>` `<Text><style>Title</style>…`),
        // falling back to the workTitle metaTag for title. There is no
        // standard subtitle metaTag, so subtitle stays nil when the
        // title frame doesn't carry one.
        let frameTexts = score.titleFrame?.texts ?? []
        let frameTitle = frameTexts.first(where: { $0.style == .title })?.text.nonEmpty
        let frameSubtitle = frameTexts.first(where: { $0.style == .subtitle })?.text.nonEmpty
        let title = frameTitle ?? score.metaTags["workTitle"]?.nonEmpty
        let subtitle = frameSubtitle
        let composer = score.metaTags["composer"]?.nonEmpty

        // Instrumentation: collect non-empty track names from parts; fall
        // back to instrument long names when trackName is nil.
        let names: [String] = score.parts.compactMap { part in
            if let track = part.trackName, !track.isEmpty { return track }
            if let track = part.instrument.trackName, !track.isEmpty { return track }
            if let long = part.instrument.longName, !long.isEmpty { return long }
            return nil
        }
        let instrumentationSummary = names.joined(separator: ", ")

        // Length: count measures on the first staff and assume 4/4. A precise
        // port would inspect each measure's TimeSig — out of scope for Plan
        // #3, refined when the Reader plan needs it.
        let measureCount = score.allStaves.first?.staff.measures.count ?? 0
        let lengthBeats = measureCount * 4

        // Default tempo: not exposed by Score.metaTags reliably; v1 default
        // matches MuseScore's own default of 120 bpm.
        let defaultTempoBpm = 120

        self.init(
            title: title,
            subtitle: subtitle,
            composer: composer,
            instrumentationSummary: instrumentationSummary,
            lengthBeats: lengthBeats,
            defaultTempoBpm: defaultTempoBpm,
            primaryKey: nil
        )
    }
}

extension String {
    fileprivate var nonEmpty: String? { isEmpty ? nil : self }
}
