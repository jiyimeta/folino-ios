// Reader v2 — Task 1 spike. Validates that hiding a staff by mutating
// `Score.staves` still renders correctly via `SheetMusicUI.ScoreView`.
// Deleted at the end of Task 10.

#if DEBUG
    import SheetMusicCore
    import SheetMusicMSCX
    import SheetMusicUI
    import SwiftUI

    private func loadSpikeScore() -> Score {
        guard let url = Bundle.module.url(forResource: "_SpikeFixture", withExtension: "mscx") else {
            fatalError("Spike fixture missing from Reader resources.")
        }
        do {
            return try MSCXParser.parse(contentsOf: url)
        } catch {
            fatalError("Spike fixture failed to parse: \(error)")
        }
    }

    /// Best-effort copy of `score` with the StaffContent at the given
    /// position dropped. `staffDeclarations` on `Part` carry no id so we
    /// cannot prune them precisely here — leaving them untouched is
    /// acceptable for the spike (Task 10 will solve the production case).
    private func dropStaff(at index: Int, in score: Score) -> Score {
        var copy = score
        guard copy.staves.indices.contains(index) else { return copy }
        copy.staves.remove(at: index)
        return copy
    }

    // Render in horizontal (single-system) mode so the preview snapshot
    // shows ALL staves of the first system at once — the differences
    // between "all" and "hide one" are otherwise invisible at the top of
    // a vertical scroll view.
    private var spikeOptions: ScoreViewOptions {
        ScoreViewOptions(
            staffSize: 22,
            systemGap: 24,
            wrapToViewWidth: false,
            includeTitleFrame: false
        )
    }

    #Preview("All staves") {
        ScrollView([.horizontal, .vertical]) {
            ScoreView(score: loadSpikeScore(), options: spikeOptions)
                .padding()
        }
    }

    #Preview("Hide staff at index 1") {
        let filtered = dropStaff(at: 1, in: loadSpikeScore())
        return ScrollView([.horizontal, .vertical]) {
            ScoreView(score: filtered, options: spikeOptions)
                .padding()
        }
    }
#endif
