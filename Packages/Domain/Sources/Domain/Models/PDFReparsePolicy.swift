import Foundation

/// Whether reading the original PDF again would throw away work the user did on top of the previous read. One rule,
/// applied by every platform, so a destructive action is never silent on one and guarded on the other.
public enum PDFReparsePolicy {
    /// - Parameters:
    ///   - isScoreEdited: the notation differs from what the conversion wrote (`ScoreItem.isPDFDerivedScoreEdited`).
    ///   - hasStaffBoundPreferences: any staff-index-addressed setting is set — clef override, hidden staff, program
    ///     or volume override, or a non-zero transpose. A better read can renumber staves, which invalidates all of
    ///     them.
    ///   - hasMusicalAnnotations: at least one stroke is anchored to the notation. Page-anchored ink on the original
    ///     is untouched by a re-read and deliberately does not count.
    public static func needsConfirmation(
        isScoreEdited: Bool,
        hasStaffBoundPreferences: Bool,
        hasMusicalAnnotations: Bool,
    ) -> Bool {
        isScoreEdited || hasStaffBoundPreferences || hasMusicalAnnotations
    }
}
