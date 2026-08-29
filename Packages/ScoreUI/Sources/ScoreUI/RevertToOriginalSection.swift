import Domain
import SwiftUI

// PARITY(android): Revert to original — Android needs the same two entry points and confirmations, plus the three
//   `original_*` columns in its Room schema and the v18 pre-stamp rule. Every decision is already a Domain pure
//   function (OriginalCapture, RevertPolicy, ScoreItem+Original) and the seam is ScoreOriginalStore, so Android
//   wires UI, persistence, and a Kotlin-side implementation of that protocol. The save choke point the capture call
//   goes at now exists on Android too — `EditorSessionCore.performSave` behind `AndroidScoreWriter` — and it already
//   calls `originals?.captureOriginalIfNeeded`, which is nil there for want of a store.

/// The score-info sheet's way back to the original. Shown only once an original exists — a score nobody has edited
/// has nothing to revert, and an inert row would just raise the question.
///
/// Unlike the editing toolbar's version, this one offers the choice of bringing the title and credits back with the
/// notation: the sheet is where those fields live, so it is the only place the distinction is legible.
struct RevertToOriginalSection: View {
    let model: any ScoreInfoEditing
    let item: ScoreItem
    let onCompleted: () -> Void

    @State private var isChoosingScope = false

    /// Whether the sidecar this section reverts to is the PDF conversion's output rather than the file the user
    /// actually imported. A PDF-origin item's imported PDF is a separate, distinct original sitting in the same
    /// sheet, so the action/footer/title below must not call the sidecar "the original" a second time (design spec,
    /// "Two originals must never be called the same thing"; Important 5 review fix).
    private var revertsToConversionOutput: Bool {
        item.originalProvenance == .conversionOutput
    }

    var body: some View {
        Section {
            // The dialog hangs off the BUTTON, not off the `Section`. A presentation modifier on a Section is
            // handed to every row it contains, and the copy that is not the one the user tapped tears the
            // presentation down the instant it opens — a bug this repo has already shipped once.
            Button(role: .destructive) {
                isChoosingScope = true
            } label: {
                Text(
                    revertsToConversionOutput ? "scoreUI.revert.action.pdf" : "scoreUI.revert.action",
                    bundle: .module,
                )
            }
            .confirmationDialog(
                Text(
                    revertsToConversionOutput ? "scoreUI.revert.confirm.title.pdf" : "scoreUI.revert.confirm.title",
                    bundle: .module,
                ),
                isPresented: $isChoosingScope,
                titleVisibility: .visible,
            ) {
                Button(role: .destructive) { revert(restoringScoreInfo: false) } label: {
                    Text("scoreUI.revert.confirm.scoreOnly", bundle: .module)
                }
                Button(role: .destructive) { revert(restoringScoreInfo: true) } label: {
                    Text("scoreUI.revert.confirm.scoreAndInfo", bundle: .module)
                }
                Button(role: .cancel) {} label: {
                    Text("scoreUI.revert.confirm.cancel", bundle: .module)
                }
            } message: {
                Text(message)
            }
        } footer: {
            Text(footer)
        }
    }

    private var footer: String {
        String(
            localized: revertsToConversionOutput ? "scoreUI.revert.footer.pdf" : "scoreUI.revert.footer",
            bundle: .module,
        )
    }

    /// `hasMusicalAnnotations: true` unconditionally — see the note in the protocol step. The ink line is worded as
    /// a possibility, so it is honest for a score with no ink at all; the provenance line still varies per item.
    private var message: String {
        let warnings = RevertPolicy.warnings(for: item, hasMusicalAnnotations: true)
        var lines = [String(localized: "scoreUI.revert.confirm.body", bundle: .module)]
        if warnings.contains(.musicalAnnotationsMayShift) {
            lines.append(String(localized: "scoreUI.revert.confirm.inkMayShift", bundle: .module))
        }
        if warnings.contains(.originalMayNotBeImportTime) {
            lines.append(String(localized: "scoreUI.revert.confirm.mayNotBeImport", bundle: .module))
        }
        return lines.joined(separator: "\n\n")
    }

    private func revert(restoringScoreInfo: Bool) {
        Task {
            await model.revertToOriginal(item, restoringScoreInfo: restoringScoreInfo)
            onCompleted()
        }
    }
}

extension RevertToOriginalSection {
    /// Whether the sheet has anything to show for this item — hoisted out of `EditScoreInfoSheet`'s body so the
    /// gating decision is testable on its own, without hosting SwiftUI (Important 6 review fix). Deliberately not
    /// just `item.canRevertToOriginal`: that Domain property is already covered by `RevertPolicyTests`, and a test
    /// suite that only re-asserted it would stay green even if `EditScoreInfoSheet` stopped calling this at all.
    static func shouldShow(_ item: ScoreItem) -> Bool {
        item.canRevertToOriginal
    }
}
