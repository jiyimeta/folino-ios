import SwiftUI

/// How much of the Reader toolbar has to fold at a given width, and the measurements that decide it. Kept apart from
/// the toolbar's own body so the arithmetic can be read — and tested — without wading through the buttons.
extension ReaderToolbar {
    /// How much of the trailing row has folded into the score-actions overflow menu, in the order the row gives things
    /// up. Ordered least to most aggressive, so `collapse >= .noteEditing` reads "note editing has folded".
    ///
    /// The order IS the priority statement: score-info and share go first, being read-once document actions; then the
    /// note-editing entry point; then annotation. The two inspectors never fold.
    enum Collapse: Int, CaseIterable, Comparable {
        /// Every action is its own button.
        case expanded
        /// Score-info and share share one ellipsis menu.
        case scoreActions
        /// …and the note-editing entry point joins them in it.
        case noteEditing
        /// …and so does the annotation toggle. Only reached on a window narrower than any iPhone.
        case annotation

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// The least aggressive collapse level whose row fits `availableWidth` — the width of the window or detail column
    /// the Reader is in, which is all a `ToolbarContent` can be told about its own size.
    ///
    /// The fallback is the most aggressive level: there is nothing further to fold, and it is the closest to fitting.
    /// A width of 0 (the first frame, before `onGeometryChange` reports) therefore starts fully collapsed, which is
    /// the safe direction — the bar never gets a chance to build an overflow menu of its own.
    static func collapse(availableWidth: CGFloat, hasLeadingAffordance: Bool, hasNoteEditing: Bool) -> Collapse {
        let budget = availableWidth
            - Metrics.barInsets
            - (hasLeadingAffordance ? Metrics.leading : 0)
        // `allCases` is declared least- to most-aggressive, so the first fit gives up the least.
        return Collapse.allCases.first {
            trailingWidth(collapse: $0, hasNoteEditing: hasNoteEditing) <= budget
        } ?? .annotation
    }

    /// What the trailing row costs in width at a given collapse level. Mirrors `ReaderToolbar.body` item for item and
    /// gap for gap — change one, change the other.
    static func trailingWidth(collapse: Collapse, hasNoteEditing: Bool) -> CGFloat {
        // The score-actions group: two buttons, or the single ellipsis menu that replaces them.
        var items = collapse >= .scoreActions ? 1 : 2
        var groups = 1
        if hasNoteEditing, collapse < .noteEditing {
            items += 1
            groups += 1
        }
        if collapse < .annotation {
            items += 1
            groups += 1
        }
        items += 2 // the two inspectors, which never fold
        return CGFloat(items) * Metrics.item + CGFloat(groups) * Metrics.groupGap
    }

    /// What one row of this toolbar costs in width, used by `ReaderRootScreen` to decide how much of it has to fold.
    ///
    /// A width breakpoint is the right mechanism here precisely because every trailing item is icon-only: there is no
    /// text to localize and nothing that grows with Dynamic Type, so what the row needs is a function of HOW MANY
    /// items it has and nothing else. What it must not be is a single number for every state — the score reader's six
    /// actions need roughly 160pt more than a PDF's three, and one constant tuned for either is wrong for the other.
    ///
    /// SwiftUI exposes no metric for a toolbar item, so `item` is not measurable directly — it is DERIVED from what
    /// real devices do, and the two observations that bracket it are worth keeping written down:
    ///
    /// - An iPhone 16 Pro (402pt) overflowed the six-button score row, so `6·item + 3·gap + leading + barInsets > 402`,
    ///   i.e. `item > 48.3`.
    /// - A 393pt iPhone must still fit the five-button row once the score actions fold, or the fold would cost the
    ///   note-input button for nothing: `5·item + 3·gap + leading + barInsets ≤ 393`, i.e. `item ≤ 56.2`.
    ///
    /// Requiring that a 440pt iPhone fold too — we have no evidence it fits six, and being wrong there is the bug this
    /// whole mechanism exists to prevent — pins the useful band to `54.7 < item ≤ 56.2`. Hence 55: the low end of that
    /// band, which is also the most generous the second constraint allows.
    ///
    /// **Re-derive whenever a button is added to the bar or its item spacing changes**, and round UP when in doubt.
    /// Over-estimating costs one discrete button that could have stayed on the bar; under-estimating hands the row to
    /// the navigation bar's OWN overflow menu, whose contents and priority we cannot influence — it takes the
    /// inspectors first, and it does not reliably open when tapped. The two failure modes are not comparable.
    enum Metrics {
        /// One icon-only button, including the spacing the bar puts between items inside a group. See above for how
        /// this number is arrived at; it carries the safety headroom itself rather than adding a second fudge factor.
        static let item: CGFloat = 55
        /// The gap a `ToolbarSpacer(.fixed)` opens between two groups.
        static let groupGap: CGFloat = 12
        /// The leading affordance — a bare chevron or the sidebar toggle. Label-less thanks to
        /// `.toolbarRole(.editor)`, so its width is fixed rather than following the previous screen's title.
        static let leading: CGFloat = 44
        /// The bar's own horizontal layout margins: its content never reaches the window edge, so the window width is
        /// NOT the budget. Leaving this out is half of why a 402pt iPhone overflowed — the fold compared against the
        /// full 402, concluded six buttons fit, and the bar disagreed.
        static let barInsets: CGFloat = 32
    }
}
