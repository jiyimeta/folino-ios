import Foundation

/// A ready-made ensemble offered when creating a score from scratch: which catalog instruments it contains, in
/// score order, and which of them a group bracket spans.
///
/// Static data in Domain for the same reason `ScoreInstrument` is — Android offers the same templates over JNI
/// rather than keeping a second list. The user-facing name is resolved in the UI layer that offers the templates
/// — on iOS the Library module's catalog, from the key `"library.newScore.template.<id>"`; nothing user-readable
/// is stored here.
public struct ScoreCreationTemplate: Sendable, Equatable, Identifiable {
    /// Stable and persisted only in analytics — a template is expanded into parts at creation time, so a score
    /// does not remember which template built it.
    public let id: String
    /// `ScoreInstrument.id`s in score order. Repeats are meaningful: a string quartet carries two violins, and
    /// each occurrence becomes its own part.
    public let instrumentIDs: [String]
    /// Half-open ranges over `instrumentIDs` to group under a `.normal` bracket. `Score.blank(_:)` converts
    /// them to global staff spans and skips any group that would bracket a single staff, so a solo template
    /// simply carries none.
    public let bracketGroups: [Range<Int>]

    init(id: String, instrumentIDs: [String], bracketGroups: [Range<Int>] = []) {
        self.id = id
        self.instrumentIDs = instrumentIDs
        self.bracketGroups = bracketGroups
    }

    public static let all: [ScoreCreationTemplate] = [
        ScoreCreationTemplate(id: "solo-piano", instrumentIDs: ["piano"]),
        ScoreCreationTemplate(id: "voice-piano", instrumentIDs: ["voice", "piano"]),
        ScoreCreationTemplate(
            id: "satb",
            instrumentIDs: ["voice-soprano", "voice-alto", "voice-tenor", "voice-bass"],
            bracketGroups: [0 ..< 4],
        ),
        ScoreCreationTemplate(
            id: "string-quartet",
            instrumentIDs: ["violin", "violin", "viola", "violoncello"],
            bracketGroups: [0 ..< 4],
        ),
    ]

    /// The catalog entries this template expands to, in score order. An id the catalog does not know is
    /// dropped rather than trapping — the templates are covered by a test that resolves every id, so a miss
    /// here means a catalog entry was renamed out from under a template.
    public var instruments: [ScoreInstrument] {
        instrumentIDs.compactMap { ScoreInstrument.instrument(id: $0) }
    }
}
