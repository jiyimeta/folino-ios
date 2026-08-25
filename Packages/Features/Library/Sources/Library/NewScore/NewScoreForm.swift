import Domain
import Foundation

/// Everything the M1 creation form collects. Presets stand in for the M2 instrument catalog: all three play
/// with the default (piano) sound; they differ in staff layout only.
struct NewScoreForm: Equatable {
    enum Preset: CaseIterable, Equatable {
        case piano // grand staff: G + F, brace
        case trebleStaff // single G staff
        case bassStaff // single F staff

        var staves: [BlankScoreTemplate.StaffPlan] {
            switch self {
            case .piano: [.init(clefType: "G"), .init(clefType: "F")]
            case .trebleStaff: [.init(clefType: "G")]
            case .bassStaff: [.init(clefType: "F")]
            }
        }
    }

    /// The key picker's menu: circle of fifths, C-major center. Raw value is `KeySignature.concertKey`.
    static let keyChoices: [Int] = [0, 1, 2, 3, 4, 5, 6, -1, -2, -3, -4, -5, -6]
    /// numerator/denominator pairs offered by the time picker.
    static let timeChoices: [(Int, Int)] = [(4, 4), (3, 4), (2, 4), (6, 8), (12, 8), (2, 2), (5, 4)]

    var title = ""
    var composer = ""
    var preset = Preset.piano
    var concertKey = 0
    // Two Ints, not a tuple: Equatable synthesis rejects tuple stored properties.
    var timeNumerator = 4
    var timeDenominator = 4
    var tempoBPM = 120
    var measureCount = 32

    /// `nil` while the form isn't submittable (empty title, same rule as `EditableScoreInfo.normalized()`).
    func template() -> BlankScoreTemplate? {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return nil }
        let trimmedComposer = composer.trimmingCharacters(in: .whitespacesAndNewlines)
        return BlankScoreTemplate(
            title: trimmedTitle,
            composer: trimmedComposer.isEmpty ? nil : trimmedComposer,
            instrumentID: "piano",
            instrumentName: "Piano",
            staves: preset.staves,
            concertKey: concertKey,
            timeNumerator: timeNumerator,
            timeDenominator: timeDenominator,
            tempoBPM: Double(tempoBPM),
            measureCount: measureCount,
        )
    }
}

/// Wraps whatever `ScoreFileCreator.createScore` throws so `LibraryViewModel.createScore(from:)` can surface a
/// creation-specific message through the shared `currentError`/`ImportErrorAlert` channel instead of the (accurate
/// but import-flavored) wording `describeLibraryError` picks for the same underlying `DomainError` case.
struct ScoreCreationFailed: LocalizedError {
    var errorDescription: String? {
        String(localized: "library.newScore.error", bundle: .module)
    }
}
