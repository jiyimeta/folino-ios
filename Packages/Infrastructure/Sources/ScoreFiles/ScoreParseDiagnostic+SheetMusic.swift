import SheetMusic

/// Bridges swift-sheet-music's `ScoreDiagnostic` (the parser's non-fatal anomaly type) into the folino-owned
/// `ScoreParseDiagnostic` seam type. Keeping the conversion here — separate from the Foundation-only seam type —
/// confines the swift-sheet-music coupling to one file.
extension ScoreParseDiagnostic {
    init(_ diagnostic: ScoreDiagnostic) {
        let severity: Severity = switch diagnostic.severity {
        case .warning: .warning
        case .info: .info
        }
        self.init(
            severity: severity,
            code: diagnostic.code,
            message: diagnostic.message,
            location: diagnostic.location,
        )
    }
}
