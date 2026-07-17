import Domain // re-exports SheetMusicCore
import Foundation
import SheetMusicLayout
import SheetMusicLayoutApple
import SheetMusicUI

/// Builds a real `LayoutDocument` from a `Score` for hit-test tests, and locates the document-space anchor of a
/// specific note / rest within it — so tests can tap "exactly on" an item without hard-coding pixel coordinates.
@MainActor
enum LayoutTestSupport {
    static func document(for score: Score, width: CGFloat = 800) -> LayoutDocument {
        _ = SheetMusicLayoutApple.install
        return LayoutEngine.layout(
            score: score,
            options: ScoreViewOptions(staffSize: 14, wrapToViewWidth: true),
            availableWidth: width,
        )
    }

    /// Document-space center of the notehead / rest for `item`, found the same way `ScoreHitTester` scans
    /// `document.systems → system.measures → measure.elements` (mirrors `ScoreHitTester.hitNote` / `hitRest` at
    /// `ScoreHitTester.swift:193-234`, including the notehead's `mirrorDx(stem:sp:)` offset). Returns nil when
    /// `item` doesn't resolve to a placed chord note or rest in `document` (tuplets / clefs are out of scope here;
    /// so is a stale id after re-layout).
    static func anchorPoint(of item: SheetMusicCore.ScoreItemID, in document: LayoutDocument) -> CGPoint? {
        let sp = document.metrics.sp
        for system in document.systems {
            for measure in system.measures {
                let base = CGPoint(
                    x: system.origin.x + measure.origin.x,
                    y: system.origin.y + measure.origin.y,
                )
                for element in measure.elements {
                    switch (item, element) {
                    case let (.note(noteID), .chord(notes, _, stem, _, _, _, _, _, _, _, _)):
                        guard let note = notes.first(where: { $0.noteID == noteID }) else { continue }
                        let mirrorDx = note.mirrorDx(stem: stem, sp: sp)
                        return CGPoint(x: base.x + note.origin.x + mirrorDx, y: base.y + note.origin.y)
                    case let (.rest(restID), .rest(_, origin, _, rid, _)):
                        guard rid == restID else { continue }
                        return CGPoint(x: base.x + origin.x, y: base.y + origin.y)
                    default:
                        continue
                    }
                }
            }
        }
        return nil
    }
}
