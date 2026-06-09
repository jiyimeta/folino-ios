import SheetMusicCore

/// A rehearsal mark resolved to a position on the seek bar, for SwiftUI consumption.
struct ReaderRehearsalMark: Identifiable {
    let id: String
    let text: String
    let fraction: Double
    let cursor: ScoreCursor
}

extension Score {
    /// Reader view-model wrapper over the shared `rehearsalMarks()` from SheetMusicCore.
    func readerRehearsalMarks() -> [ReaderRehearsalMark] {
        rehearsalMarks().enumerated().map { index, entry in
            ReaderRehearsalMark(
                id: "\(index)-\(entry.text)",
                text: entry.text,
                fraction: entry.fraction,
                cursor: entry.cursor,
            )
        }
    }
}
