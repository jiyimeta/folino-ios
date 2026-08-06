import SwiftUI

/// The display globals the PiP renderer has to re-engrave for. Bundled into one `Equatable` value so the Reader can
/// mirror them with a single `onChange` instead of one per toggle — the list grows every time a new render option
/// ships, and a missing observer shows up only as a PiP window that quietly renders the previous setting.
///
/// Each setter on the session is a no-op when the value is unchanged, so pushing all four on any single change costs
/// nothing: the session decides whether a rearm is warranted.
struct PiPDisplayOptions: Equatable {
    let isEnabled: Bool
    let collapseMultiMeasureRests: Bool
    let showInvisibleElements: Bool
    let showAllMeasureNumbers: Bool

    @MainActor
    func apply(to session: ReaderPiPSession) {
        session.setEnabled(isEnabled)
        session.setCollapseMultiMeasureRests(collapseMultiMeasureRests)
        session.setShowInvisibleElements(showInvisibleElements)
        session.setShowAllMeasureNumbers(showAllMeasureNumbers)
    }
}
