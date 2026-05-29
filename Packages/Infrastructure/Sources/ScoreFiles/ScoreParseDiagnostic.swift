import Foundation

/// folino-owned mirror of swift-sheet-music's `ScoreDiagnostic`, used as the seam between the (not-yet-released)
/// parser diagnostics API and folino's telemetry pipeline. Owned by folino so the whole pipeline can be built and
/// tested before the upstream branch lands; once it does, add `init(_ ssm: ScoreDiagnostic)` to bridge.
///
/// Kept in `ScoreFiles` (not Domain) because it is telemetry-only — no Feature or Domain consumer references it.
struct ScoreParseDiagnostic: Hashable {
    enum Severity: Hashable {
        /// Recoverable: the offending element was dropped or defaulted.
        case warning
        /// Notable but expected (e.g. MS2 compatibility path).
        case info
    }

    let severity: Severity
    /// Stable, machine-readable identifier, e.g. `"mscx.tremolo.unknownSubtype"`.
    let code: String
    /// Human-readable English message. Sent verbatim — no truncation.
    let message: String
    /// Best-effort in-score location, e.g. `"measure 12, voice 1, Tremolo"`. `nil` when unavailable.
    let location: String?
}
