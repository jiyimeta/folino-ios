import Domain
import SwiftUI

/// How a Library row is opened, per platform — the two halves of one decision, kept in one file so neither can be
/// changed without seeing the other.
///
/// **iOS taps the row. macOS puts no gesture on it at all.** That is not a style preference; a SwiftUI tap gesture
/// and `List(selection:)` cannot coexist on macOS, measured:
///
/// | gesture on the row | single-click selects | ⌘-click extends | double-click fires |
/// | --- | --- | --- | --- |
/// | none | YES | YES | — |
/// | `.onTapGesture` | NO | NO | (fires as a single tap) |
/// | `.onTapGesture(count: 2)` | NO | NO | YES |
/// | `.simultaneousGesture(TapGesture(count: 2))` | NO | NO | YES |
/// | `.highPriorityGesture(TapGesture(count: 2))` | NO | NO | YES |
/// | `contextMenu(forSelectionType:primaryAction:)` | unmeasured | unmeasured | unmeasured |
///
/// Every gesture form leaves `List(selection:)` permanently EMPTY — not merely unable to multi-select, but unable to
/// select at all. Each failing row above fired its open action in the same measured run, so the events reach SwiftUI;
/// what they never reach is the `NSTableView` underneath, because the gesture claims the click first. Attaching to
/// the whole row instead of its content changes nothing, and `.contentShape(Rectangle())` alone is innocent.
/// `contextMenu(forSelectionType:primaryAction:)` is a `List` API rather than a gesture overlay, so nothing above
/// condemns it — but nothing measured it either, so it stays `unmeasured` until QA exercises a real double-click; see
/// `macScoreOpenAffordance` below for what it currently drives.
///
/// The consequence is why this matters: with the selection permanently empty, the Mac's bulk-action context menu
/// (`selectedIDs.count > 1`) and its ⌫ binding (`guard !selectedIDs.isEmpty`) were both unreachable, silently.
///
/// **Selection no longer opens a row either — spec §2.2 severs that link.** A one-row selection used to be read as
/// "open this score," which made a deliberate single-item bulk selection indistinguishable from "show me this
/// score," and meant a stray ⌘-click on another row silently tore down whatever was open. `macScoreOpenAffordance`
/// below is the row's opening action now: never a gesture, and never a side effect of selecting or deselecting.
extension View {
    /// The row's tap-to-open gesture — **iOS only**. A no-op on macOS, where any tap gesture would empty
    /// `List(selection:)`; see this file's doc comment for the measurement, and `macScoreOpenAffordance` for what
    /// opens a row there instead.
    ///
    /// A helper rather than an inline `#if` because these calls sit inside a modifier chain, and SwiftFormat's
    /// `--ifdef no-indent` de-indents the whole chain when a `#if` interrupts one of its links.
    @ViewBuilder
    func rowTapToOpenCompat(perform action: @escaping () -> Void) -> some View {
        #if os(iOS)
        onTapGesture(perform: action)
        #else
        self
        #endif
    }

    /// **macOS only**: how a score row is opened, now that selecting it does not.
    ///
    /// Four paths were the plan: double-click (via `primaryAction:` below), Return, the row's own context menu, and
    /// a caller-supplied button — with the last three treated as the real fallback, not garnish, since
    /// `contextMenu(forSelectionType:primaryAction:)` is unmeasured here (the new table row above).
    ///
    /// **Only two of those four live in this helper.** `ScoreListView.effectiveRowMenu` (and its equivalents in
    /// `PlaylistDetailView` and `RecentlyDeletedView`) already install a `.contextMenu` on every row that switches to
    /// bulk actions once more than one row is selected. A *second*, List-level menu from
    /// `contextMenu(forSelectionType:)` on the same rows would fight that one for the same click — this is the same
    /// "two menus on one row" hazard the measurement above documents for gestures, just one level up the API. So this
    /// helper's own `menu:` closure is empty on purpose, and Open / Open in New Window are built into each caller's
    /// existing row menu instead, calling `onOpen` / `onOpenInNewWindow` directly. What this helper contributes is
    /// `primaryAction:` (double-click) and Return; the caller-supplied-button path is whatever UI a later task hangs
    /// off the same two closures — this file does not build one.
    ///
    /// **`onOpenInNewWindow` is not called from this helper, and that is the second unbuilt open affordance.** Spec
    /// §2.3 gives opening two shapes: the default (a new tab of the frontmost score window, or a standalone window
    /// when there is none) and **⌥-double-click for Open in New Window**. Only the default was built.
    /// `contextMenu(forSelectionType:primaryAction:)` hands `primaryAction:` a selection and nothing else — no
    /// modifier flags, no event — so the ⌥ half cannot be read at the one place a double-click arrives, and reading
    /// `NSEvent.modifierFlags` at that moment would be guessing at whether the flag belongs to this click. The
    /// parameter stays because it is live: every caller's own row `.contextMenu` builds an **Open in New Window**
    /// item on it, which is the affordance the user actually has. Alongside the toolbar Open button the spec also
    /// names and nothing built (`macScoreOpenAffordance`'s doc above, and the QA sheet), these are the two open
    /// affordances the spec describes and this branch does not ship — both are on the QA sheet's known-deviation
    /// note, and closing the ⌥ one means an open path that carries the modifier, not a change here.
    ///
    /// **What was actually verified here, and what was not.** `Scripts/build-macos-packages.sh` compiles this
    /// helper and every call site with `menu:` empty, so the "two menus" collision the paragraph above describes
    /// cannot arise from a type-check standpoint — there is only ever one populated `.contextMenu` per row. Which
    /// menu a human sees on a real right-click, and whether `primaryAction:` actually fires on a real double-click,
    /// were not observed by this change: that needs a running app and a pointer, not a build log. Both are on the
    /// QA sheet in `task-2-report.md`; if double-click turns out dead, Return and the context-menu item are already
    /// real, working fallbacks — see the previous paragraph.
    @ViewBuilder
    func macScoreOpenAffordance(
        _ selectedIDs: Set<ScoreItemID>,
        in items: [ScoreItem],
        onOpen: @escaping (ScoreItem) -> Void,
        onOpenInNewWindow: @escaping (ScoreItem) -> Void,
    ) -> some View {
        #if os(macOS)
        contextMenu(forSelectionType: ScoreItemID.self) { _ in
            // Empty on purpose — see this function's doc comment. A populated menu here would compete with the
            // caller's own per-row `.contextMenu` for the same rows; Open / Open in New Window live there instead.
        } primaryAction: { ids in
            guard let item = macRowOpenAffordanceSingleItem(ids, in: items) else { return }
            onOpen(item)
        }
        .onKeyPress(.return) {
            guard let item = macRowOpenAffordanceSingleItem(selectedIDs, in: items) else { return .ignored }
            onOpen(item)
            return .handled
        }
        #else
        self
        #endif
    }
}

#if os(macOS)
/// Exactly one selected row, or `nil` — shared by `macScoreOpenAffordance`'s `primaryAction` and its Return handler.
///
/// Not a `static` member on the `View` extension above: a protocol extension cannot add a static member reachable as
/// `Self.foo` from inside another extension method the way an earlier draft of this helper assumed, so this is a
/// free function instead.
private func macRowOpenAffordanceSingleItem(_ ids: Set<ScoreItemID>, in items: [ScoreItem]) -> ScoreItem? {
    guard ids.count == 1, let id = ids.first else { return nil }
    return items.first { $0.id == id }
}
#endif
