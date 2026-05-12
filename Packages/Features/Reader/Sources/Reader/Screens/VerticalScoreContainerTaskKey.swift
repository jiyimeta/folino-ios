import CoreGraphics
import SheetMusicCore

extension VerticalScoreContainer {
    /// Hashable composite key so `.task(id:)` re-runs only when one of
    /// the inputs to layout actually changes.
    struct TaskKey: Hashable {
        let scoreSignature: Int
        let size: CGFloat
        let width: CGFloat
        let honorLayoutBreaks: Bool
        let collapseMultiMeasureRests: Bool

        init(
            score: Score,
            size: CGFloat,
            width: CGFloat,
            honorLayoutBreaks: Bool,
            collapseMultiMeasureRests: Bool,
        ) {
            // `Score` is Equatable but not Hashable. Use a cheap
            // identity proxy: structural shape + opening clefs. The
            // opening-clef hash is what makes a clef override (a
            // field-level edit that leaves parts.count / staff count
            // unchanged) re-trigger this `.task(id:)`.
            scoreSignature = score.parts.count
                ^ (score.totalStaffCount << 8)
                ^ (score.division << 16)
                ^ score.openingClefSignature
            self.size = size
            self.width = width
            self.honorLayoutBreaks = honorLayoutBreaks
            self.collapseMultiMeasureRests = collapseMultiMeasureRests
        }
    }
}
