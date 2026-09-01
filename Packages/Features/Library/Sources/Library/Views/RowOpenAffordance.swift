import Domain
import SwiftUI

/// How a Library row is opened, per platform — the two halves of one decision, kept in one file so neither can be
/// changed without seeing the other.
///
/// **iOS taps the row. macOS selects it, and selecting is what opens it.** That is not a style preference; a
/// SwiftUI tap gesture and `List(selection:)` cannot coexist on macOS, measured:
///
/// | gesture on the row | single-click selects | ⌘-click extends | double-click fires |
/// | --- | --- | --- | --- |
/// | none | YES | YES | — |
/// | `.onTapGesture` | NO | NO | (fires as a single tap) |
/// | `.onTapGesture(count: 2)` | NO | NO | YES |
/// | `.simultaneousGesture(TapGesture(count: 2))` | NO | NO | YES |
/// | `.highPriorityGesture(TapGesture(count: 2))` | NO | NO | YES |
///
/// Every gesture form leaves `List(selection:)` permanently EMPTY — not merely unable to multi-select, but unable to
/// select at all. Each failing row above fired its open action in the same measured run, so the events reach SwiftUI;
/// what they never reach is the `NSTableView` underneath, because the gesture claims the click first. Attaching to
/// the whole row instead of its content changes nothing, and `.contentShape(Rectangle())` alone is innocent.
///
/// The consequence is why this matters: with the selection permanently empty, the Mac's bulk-action context menu
/// (`selectedIDs.count > 1`) and its ⌫ binding (`guard !selectedIDs.isEmpty`) were both unreachable, silently.
///
/// So on macOS the row carries no gesture and `macSelectionOpensScore` turns a one-row selection into the open.
/// Spec §3.2 originally called for double-click; that is measured impossible, and the spec now records this table.
extension View {
    /// The row's tap-to-open gesture — **iOS only**. A no-op on macOS, where any tap gesture would empty
    /// `List(selection:)`; see this file's doc comment for the measurement, and `macSelectionOpensScore` for what
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

    /// **macOS only**: a selection of exactly one row is the open gesture.
    ///
    /// Above one, nothing opens — the selection is a bulk selection, and the Mac shell shows a count in the detail
    /// instead. Below one, nothing opens either: clearing the selection leaves whatever was open on screen rather
    /// than emptying the detail, which is what Mail and Finder do and what stops a stray ⌘-click from closing a
    /// score the user is reading.
    ///
    /// **Exactly one state write reaches the shell from here**, and that is deliberate: `onOpen` is expected to set
    /// the presented score and nothing else. A second write made from this handler re-enters the split view's
    /// navigation observer in the same frame — see `MacShellView.openImportedScore` for the measurements that rule
    /// records. In particular the sidebar must NOT be collapsed here: it would be a second write, and collapsing the
    /// sidebar on the first click would make ⌘-clicking a second row impossible.
    @ViewBuilder
    func macSelectionOpensScore(
        _ selectedIDs: Set<ScoreItemID>,
        in items: [ScoreItem],
        onOpen: @escaping (ScoreItem) -> Void,
    ) -> some View {
        #if os(macOS)
        onChange(of: selectedIDs) { _, newValue in
            guard newValue.count == 1, let id = newValue.first,
                  let item = items.first(where: { $0.id == id })
            else { return }
            onOpen(item)
        }
        .focusedSceneValue(\.libraryBulkSelectionCount, selectedIDs.count)
        #else
        self
        #endif
    }
}

#if os(macOS)
extension FocusedValues {
    private struct LibraryBulkSelectionCountKey: FocusedValueKey {
        typealias Value = Int
    }

    /// How many Library rows are selected in this window, published so the Mac shell's detail column can show a
    /// "N selected" state instead of a reader.
    ///
    /// A focused **scene** value rather than a callback threaded down through `LibraryRootScreen`: the selection
    /// lives in three different screens' `@State`, each several pushes deep inside the sidebar's `NavigationStack`,
    /// and a parameter would have to cross the Library package's screen signatures — and iOS call sites — to carry
    /// something only the Mac shell reads. `MacShellView` already publishes `macCurrentScoreID` and
    /// `macLibraryImportAction` the same way. Scene-scoped, so it survives focus moving into the detail column.
    public var libraryBulkSelectionCount: Int? {
        get { self[LibraryBulkSelectionCountKey.self] }
        set { self[LibraryBulkSelectionCountKey.self] = newValue }
    }
}
#endif
