@testable import Domain
import Testing
import UtilityCore

struct ScorePrefsEventTests {
    private let scoreID = ScoreItemID()
    private let staffA = StaffAddress(partIndex: 0, staffIndexInPart: 0)
    private let staffB = StaffAddress(partIndex: 1, staffIndexInPart: 0)

    @Test func `an all-untouched row produces no event`() {
        let prefs = ReaderPreferences(scoreItemID: scoreID, hiddenStaves: [])
        #expect(AnalyticsEvent.scorePrefs(prefs, screenWidthPt: 430) == nil)
    }

    @Test func `a single touched field emits exactly that param plus width`() throws {
        let prefs = ReaderPreferences(scoreItemID: scoreID, staffSize: 18, hiddenStaves: [])
        let event = try #require(AnalyticsEvent.scorePrefs(prefs, screenWidthPt: 430))
        #expect(event.name == "score_prefs")
        #expect(event.parameters["staff_size"] == .int(18))
        #expect(event.parameters["screen_width_pt"] == .int(430))
        #expect(event.parameters.count == 2)
    }

    @Test func `explicit false honor breaks is present`() throws {
        let prefs = ReaderPreferences(scoreItemID: scoreID, hiddenStaves: [], honorLayoutBreaks: false)
        let event = try #require(AnalyticsEvent.scorePrefs(prefs, screenWidthPt: 375))
        #expect(event.parameters["honor_layout_breaks"] == .bool(false))
    }

    /// A stored value equal to the default still counts as touched — that is the whole point of Task 1's Optionals.
    @Test func `a deliberately re-chosen default is still reported`() throws {
        let prefs = ReaderPreferences(
            scoreItemID: scoreID, hiddenStaves: [],
            honorLayoutBreaks: true,
            masterVolume: ReaderPreferences.defaultMasterVolume,
            transposeSemitones: ReaderPreferences.defaultTransposeSemitones,
        )
        let event = try #require(AnalyticsEvent.scorePrefs(prefs, screenWidthPt: 375))
        #expect(event.parameters["honor_layout_breaks"] == .bool(true))
        #expect(event.parameters["master_volume_pct"] == .int(100))
        #expect(event.parameters["transpose_semitones"] == .int(0))
    }

    @Test func `percent params round to 10 percent steps`() throws {
        let prefs = ReaderPreferences(
            scoreItemID: scoreID, hiddenStaves: [],
            tempoMultiplier: 0.5, masterVolume: 3.0,
        )
        let event = try #require(AnalyticsEvent.scorePrefs(prefs, screenWidthPt: 375))
        #expect(event.parameters["master_volume_pct"] == .int(300))
        #expect(event.parameters["tempo_multiplier_pct"] == .int(50))
    }

    @Test func `percent params snap an off-step value to the nearest step`() throws {
        let prefs = ReaderPreferences(
            scoreItemID: scoreID, hiddenStaves: [],
            tempoMultiplier: 1.23, masterVolume: 0.55,
        )
        let event = try #require(AnalyticsEvent.scorePrefs(prefs, screenWidthPt: 375))
        #expect(event.parameters["tempo_multiplier_pct"] == .int(120))
        #expect(event.parameters["master_volume_pct"] == .int(60))
    }

    @Test func `hid and reveal counts come from the two sets`() throws {
        var prefs = ReaderPreferences(scoreItemID: scoreID, hiddenStaves: [staffA], authoredHiddenStaves: [staffB])
        // staffA is user-hidden (not authored); staffB is authored but visible == user-revealed.
        let event = try #require(AnalyticsEvent.scorePrefs(prefs, screenWidthPt: 375))
        #expect(event.parameters["hidden_staff_count"] == .int(1))
        #expect(event.parameters["revealed_staff_count"] == .int(1))
        // Authored-only hides emit neither param.
        prefs.hiddenStaves = [staffB]
        prefs.authoredHiddenStaves = [staffB]
        #expect(AnalyticsEvent.scorePrefs(prefs, screenWidthPt: 375) == nil)
    }

    @Test func `override dictionaries report counts`() throws {
        let prefs = ReaderPreferences(
            scoreItemID: scoreID, hiddenStaves: [],
            staffProgramOverrides: [staffA: 40], staffVolumeOverrides: [staffA: 0.5, staffB: 0.7],
            staffClefOverrides: [staffA: "F"],
        )
        let event = try #require(AnalyticsEvent.scorePrefs(prefs, screenWidthPt: 375))
        #expect(event.parameters["program_override_count"] == .int(1))
        #expect(event.parameters["volume_override_count"] == .int(2))
        #expect(event.parameters["clef_override_count"] == .int(1))
    }

    @Test func `a4 reference rounds to whole hz`() throws {
        let prefs = ReaderPreferences(scoreItemID: scoreID, hiddenStaves: [], a4ReferenceHz: 441.6)
        let event = try #require(AnalyticsEvent.scorePrefs(prefs, screenWidthPt: 375))
        #expect(event.parameters["a4_reference_hz"] == .int(442))
    }

    /// `repeatMode` / `abRepeat` are deliberately not part of `score_prefs` — repeat mode is a global sticky setting
    /// covered by `settings_snapshot`, and neither has a per-score parameter here.
    @Test func `repeat state alone does not make a row touched`() {
        let prefs = ReaderPreferences(
            scoreItemID: scoreID, hiddenStaves: [],
            repeatMode: .abLoop,
            abRepeat: ABRepeatRange(
                start: ChordPath(systemIndex: 0, measureIndex: 0, voiceIndex: 0, chordIndex: 0),
                end: ChordPath(systemIndex: 0, measureIndex: 4, voiceIndex: 0, chordIndex: 0),
            ),
        )
        #expect(AnalyticsEvent.scorePrefs(prefs, screenWidthPt: 375) == nil)
    }

    /// Every declared param appears together, and nothing else rides along.
    @Test func `a fully touched row emits all twelve params`() throws {
        let prefs = ReaderPreferences(
            scoreItemID: scoreID, staffSize: 16,
            hiddenStaves: [staffA], authoredHiddenStaves: [staffB],
            staffProgramOverrides: [staffA: 40], staffVolumeOverrides: [staffA: 0.5],
            staffClefOverrides: [staffA: "F"],
            tempoMultiplier: 1.2, honorLayoutBreaks: false,
            masterVolume: 0.8, transposeSemitones: -3, a4ReferenceHz: 442,
        )
        let event = try #require(AnalyticsEvent.scorePrefs(prefs, screenWidthPt: 430))
        #expect(Set(event.parameters.keys) == [
            "staff_size", "honor_layout_breaks", "master_volume_pct", "transpose_semitones",
            "tempo_multiplier_pct", "a4_reference_hz", "hidden_staff_count", "revealed_staff_count",
            "program_override_count", "volume_override_count", "clef_override_count", "screen_width_pt",
        ])
    }

    @Test func `screen width floors to the breakpoint table`() {
        #expect(AnalyticsEvent.screenWidthBucket(507) == 430)
        #expect(AnalyticsEvent.screenWidthBucket(300) == 320)
        #expect(AnalyticsEvent.screenWidthBucket(320) == 320)
        #expect(AnalyticsEvent.screenWidthBucket(834) == 834)
        #expect(AnalyticsEvent.screenWidthBucket(1400) == 1366)
    }

    /// Each breakpoint is exact-inclusive, and one point below it falls to the previous bucket.
    @Test func `every breakpoint is inclusive at its own edge`() {
        let breakpoints = [320, 375, 390, 430, 744, 834, 1024, 1366]
        for (index, breakpoint) in breakpoints.enumerated() {
            #expect(AnalyticsEvent.screenWidthBucket(Double(breakpoint)) == breakpoint)
            let expectedBelow = index == 0 ? 320 : breakpoints[index - 1]
            #expect(AnalyticsEvent.screenWidthBucket(Double(breakpoint) - 1) == expectedBelow)
        }
        #expect(AnalyticsEvent.screenWidthBucket(0) == 320)
    }

    @Test func `enumeration filters trashed scores and untouched rows`() {
        let liveID = ScoreItemID()
        let trashedID = ScoreItemID()
        let untouchedID = ScoreItemID()
        let rows = [
            ReaderPreferences(scoreItemID: liveID, staffSize: 18, hiddenStaves: []),
            ReaderPreferences(scoreItemID: trashedID, staffSize: 20, hiddenStaves: []),
            ReaderPreferences(scoreItemID: untouchedID, hiddenStaves: []),
        ]
        let events = AnalyticsEvent.scorePrefsEvents(
            allPreferences: rows, liveScoreItemIDs: [liveID, untouchedID], screenWidthPt: 430,
        )
        #expect(events.count == 1)
        #expect(events[0].parameters["staff_size"] == .int(18))
    }
}
