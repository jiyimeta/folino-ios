import SwiftUI

// PARITY(macos): sheet Esc / Return key equivalents — four Library sheet buttons still reach these neutral
//   placements instead of `.cancellationAction` / `.confirmationAction`, so those Mac sheets have no Esc and no
//   default button. Task 16 migrated one screen at a time, diffing each against its own rendered preview, and
//   stopped where the iOS render moved: `.confirmationAction` renders a TEXT Done semibold where iOS renders it
//   regular, and `.cancellationAction` resolves to the LEADING slot, which throws a deliberately trailing Cancel
//   across the bar. What is left is a decision rather than more migration — accept the semibold Done on iOS
//   (which is what the platform asks for anyway), or pin the label's weight so the semantic placement keeps
//   today's look. Be clear about how small the shipped win is: of the five migrations, exactly ONE is reachable
//   on a Mac — BulkEditTagsSheet's Cancel, which now takes Esc. ShareRootView's four are semantically right at
//   zero measured cost but have no macOS host at all (only the iOS share extension presents it), and two of
//   those four are inside `private struct PreviewLoaded`, which ships nothing. Per-screen measurements are
//   below and at each call site.
//
//   - `.cancellationAction` is identical to `topBarLeadingCompat` on iOS, within ±1 per channel over the whole
//     frame. BulkEditTagsSheet's Cancel and ShareRootView's two Cancels migrated on that evidence;
//     ShareRootView's two confirms migrated on the next bullet's.
//   - `.confirmationAction`'s semibold cost 1492 px inside the button on AddToPlaylistSheet and EditTagsSheet,
//     1362 on BulkEditTagsSheet. A confirm carrying an explicit button style is immune — ShareRootView's
//     glass-prominent checkmark came out identical within the same tolerance, in both its disabled and its
//     enabled state — so this is about the label's font weight, not the placement.
//   - BulkAddToPlaylistSheet's Cancel is the only bar button on its sheet and is deliberately trailing.
//     Migrating it moved it across the bar and dragged the title with it: 17430 px.
//
//   The Mac keyboard payoff is measured, not assumed (Task 16, standalone AppKit probe against real sheets,
//   the event addressed to the SHEET window's number): `.cancellationAction` fires on Esc and
//   `.confirmationAction` fires on Return, while the two neutral placements this file substitutes —
//   `.navigation` and `.primaryAction` — fire on neither. Both directions came from the same run, so the
//   negatives are not a dead delivery path. So the semibold Done above is not a cost for nothing: it is what
//   Return costs.
//
//   Leaving a sheet on MIXED placements — a semantic Cancel beside a neutral Done — costs nothing on the Mac,
//   which is not obvious and was measured rather than assumed. Rendered against a macOS destination,
//   BulkEditTagsSheet's mixed toolbar is identical (±1 per channel, 1200x1024) to the same sheet with BOTH
//   buttons semantic: `.cancellationAction` and `.primaryAction` group at the trailing edge in that order, which
//   is where a Mac expects Cancel and a default button. It is the pre-migration layout that was wrong — with
//   both on these helpers, `.navigation` put Cancel hard against the traffic lights with Done alone at the far
//   trailing edge (17944 px apart in the toolbar band). So a holdout Done is a missing Return key, not a
//   misplaced button.
//
//   Weigh the decision knowing the rest of the app already went the other way. Every sheet wearing the house
//   confirm/close chrome — `SheetActionLabel` / `SheetConfirmButton`, five of them across Editor and ScoreUI —
//   is already on semantic placements, and asks no weight question at all because its labels are glyphs with an
//   explicit prominent style. `NewScoreSheet`, in the same package as the four holdouts, is already on
//   `.confirmationAction` with a plain TEXT "Create", so a semibold text confirmation is a look this app
//   ships today. The four holdouts are simply the last sheets still drawing "Cancel" / "Done" as words in plain
//   buttons, so the tidiest close is probably to give them the house chrome first and let the placement follow —
//   but that changes what a shipped screen looks like, which is not the migration's call to make.
//
//   Two things are deliberately NOT in this gap. `doneToolbarCompat` below emits no macOS toolbar item at all,
//   so migrating its iOS branch would be pure iOS risk for no Mac keyboard gain. And the sites holding a menu,
//   an overflow, a spacer or the Settings-gear seam — ScoreListView, LibraryRootScreen, ManageEntityToolbar,
//   CreateEntityToolbar — are neither a cancellation nor a confirmation, and belong on a neutral placement.

extension ToolbarItemPlacement {
    /// `.topBarLeading` on iOS; `.navigation` on macOS, which is the leading edge of a Mac toolbar.
    public static var topBarLeadingCompat: ToolbarItemPlacement {
        #if os(iOS)
        .topBarLeading
        #else
        .navigation
        #endif
    }

    /// `.topBarTrailing` on iOS; `.primaryAction` on macOS, which is the trailing edge of a Mac toolbar.
    public static var topBarTrailingCompat: ToolbarItemPlacement {
        #if os(iOS)
        .topBarTrailing
        #else
        .primaryAction
        #endif
    }
}

extension View {
    /// `.navigationBarTitleDisplayMode(.inline)` on iOS; a no-op on macOS, which has no large-title collapse.
    @ViewBuilder
    public func inlineNavigationTitleCompat() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// `.textInputAutocapitalization(.words)` on iOS; a no-op on macOS, which has no software keyboard to steer.
    @ViewBuilder
    public func wordCapitalizationCompat() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.words)
        #else
        self
        #endif
    }

    /// `.keyboardType(.numberPad)` on iOS; a no-op on macOS, which has a hardware keyboard and nothing to
    /// constrain. The field still refuses non-numeric input through its `format:`, on both platforms.
    @ViewBuilder
    public func numberPadKeyboardCompat() -> some View {
        #if os(iOS)
        keyboardType(.numberPad)
        #else
        self
        #endif
    }

    /// Pins a `List` into edit mode on iOS, so its rows carry reorder handles and delete minuses without an
    /// `EditButton` first; a no-op on macOS, which has no `EditMode` at all.
    ///
    /// A helper rather than an inline `#if` because SwiftFormat's `--ifdef no-indent` de-indents an entire
    /// modifier chain that a `#if` interrupts, and then fights the next commit over it.
    ///
    /// PARITY(macos): list row deletion without a swipe — the sheets that call this show no delete minus on macOS,
    ///   and their `.onDelete` has no other way in: ⌫ reaches SwiftUI's `deleteBackward:` only when something calls
    ///   `interpretKeyEvents` directly, which the ordinary `keyDown` path does not (measured, Task 15). What macOS
    ///   needs is an explicit per-row Remove affordance — a context-menu item — on each list that declares
    ///   `.onDelete`. Reordering is believed NOT to be part of this gap: `.onMove` alone already makes a macOS row
    ///   draggable with no edit mode (measured, Task 15 — but only the drag SOURCE was measured; SwiftUI gates the
    ///   drop on a live `NSDraggingSession`, which no in-process harness can construct, so the on-screen drop is
    ///   still unverified by hand. If a Mac row picks up but will not drop, reordering belongs in this gap after
    ///   all).
    @ViewBuilder
    public func activeEditModeCompat() -> some View {
        #if os(iOS)
        environment(\.editMode, .constant(.active))
        #else
        self
        #endif
    }

    /// Mirrors a bulk-selection `isSelecting` flag into `\.editMode` on iOS, which drives a `List`'s row checkmarks
    /// and reorder/delete affordances; a no-op on macOS, which has no `EditMode` at all (the type itself is
    /// unavailable there) — `List(selection:)` already multi-selects natively with ⌘/⇧-click.
    ///
    /// A helper rather than an inline `#if` for the same reason as `activeEditModeCompat()`: this sits in the middle
    /// of a modifier chain, and SwiftFormat's `--ifdef no-indent` de-indents the whole chain when a `#if` interrupts
    /// one of its links.
    @ViewBuilder
    public func bulkSelectionEditModeCompat(isSelecting: Bool) -> some View {
        #if os(iOS)
        environment(\.editMode, .constant(isSelecting ? .active : .inactive))
        #else
        self
        #endif
    }

    /// Binds `action` to the ⌫ key, on macOS only; a no-op on iOS, which has no hardware delete key to bind (and
    /// keeps reaching bulk delete through the bar's trash button). `action` is responsible for its own emptiness
    /// guard — this fires on every ⌫ press regardless of whether anything is selected.
    ///
    /// A helper rather than an inline `#if` for the same reason as `activeEditModeCompat()`: this sits inside a
    /// modifier chain, and SwiftFormat's `--ifdef no-indent` de-indents the whole chain when a `#if` interrupts one
    /// of its links.
    @ViewBuilder
    public func deleteCommandCompat(perform action: @escaping () -> Void) -> some View {
        #if os(macOS)
        onDeleteCommand(perform: action)
        #else
        self
        #endif
    }

    /// Floors a macOS sheet's HEIGHT; a no-op on iOS, where a sheet is sized by its detent, not its content.
    ///
    /// A macOS sheet sizes itself to its content's ideal size, and a `List` has no ideal height to offer — so a
    /// `NavigationStack { List { … } }` presented as a sheet collapses to AppKit's minimum, **80 points tall**,
    /// with the whole list crammed into a scroller barely one row high. Measured on the Mac's tag and playlist
    /// sheets (Task 15): 470x80, unchanged 6.5 seconds after presentation, and byte-for-byte the same size as a
    /// sheet presenting `EmptyView`. Content-sized sheets built on `Form` (the new-score wizard's own outer sheet,
    /// Edit Info) are unaffected — they report a real height — so this belongs on the list-shaped sheets only.
    ///
    /// **Only height is floored, because only height collapsed.** Width came out at 470 on every sheet measured,
    /// empty or not, so a width floor below that would never bind and one above it would be inventing a
    /// requirement no measurement supports.
    ///
    /// **460 is a judgement, not a measurement** — roughly a dozen list rows plus the navigation bar, enough to
    /// browse a tag or playlist list without the sheet dominating the window. What is measured is the 80 it
    /// replaces, and that any of these sheets left alone is unusable.
    ///
    /// Not exhaustive across the app: `EditorInstrumentsSheet` hosts the same `InstrumentCatalogPicker` list in the
    /// same `NavigationStack { List }` shape and does NOT call this — it is outside the Library, and belongs to
    /// whoever ports the Editor to the Mac.
    @ViewBuilder
    public func listSheetSizeCompat() -> some View {
        #if os(macOS)
        frame(minHeight: 460)
        #else
        self
        #endif
    }

    /// A right-click context menu, on macOS only; a no-op on iOS. For rows whose iOS affordance is a swipe, which
    /// macOS has no gesture for: the Mac reaches the same actions from the row's context menu, and iOS keeps the
    /// swipe it already has rather than gaining a long-press menu it never had.
    ///
    /// A helper rather than an inline `#if` for the same reason as `activeEditModeCompat()`: this sits inside a
    /// modifier chain, and SwiftFormat's `--ifdef no-indent` de-indents the whole chain when a `#if` interrupts one
    /// of its links.
    @ViewBuilder
    public func macContextMenuCompat(@ViewBuilder content: @escaping () -> some View) -> some View {
        #if os(macOS)
        contextMenu(menuItems: content)
        #else
        self
        #endif
    }

    /// A trailing "Done" toolbar button that calls `action`, on iOS; a no-op on macOS. Content built to be
    /// presented as an iOS sheet draws its own Done button to dismiss that sheet; the same content hosted directly
    /// in a macOS `Settings` scene has nothing analogous to dismiss — the window closes via its own titlebar
    /// controls — so this drops the button entirely rather than wiring it to an action with no effect.
    ///
    /// A helper rather than an inline `#if` for the same reason as `activeEditModeCompat()`: this sits inside a
    /// modifier chain, and SwiftFormat's `--ifdef no-indent` de-indents the whole chain when a `#if` interrupts one
    /// of its links.
    ///
    /// PARITY(macos): SettingsSheet dismiss chrome — iOS's Done button assumes the screen is always presented as a
    ///   dismissible sheet; a macOS `Settings` scene hosts the same content directly, with no presentation to
    ///   dismiss, so this drops the button rather than adapting it.
    @ViewBuilder
    public func doneToolbarCompat(action: @escaping () -> Void) -> some View {
        #if os(iOS)
        toolbar {
            ToolbarItem(placement: .topBarTrailingCompat) {
                Button(action: action) { L10n.Common.done }
            }
        }
        #else
        self
        #endif
    }

    /// Presents `content` as a popover anchored to whichever view this is attached to, on macOS only; a no-op on
    /// iOS. For a confirmation that a Mac reaches from a keyboard command or a context menu, where iOS reaches the
    /// same confirmation from a bulk-action bar that carries its own popover.
    ///
    /// A helper rather than an inline `#if` for the same reason as `activeEditModeCompat()`: this sits inside a
    /// modifier chain, and SwiftFormat's `--ifdef no-indent` de-indents the whole chain when a `#if` interrupts one
    /// of its links.
    @ViewBuilder
    public func popoverCompat(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> some View,
    ) -> some View {
        #if os(macOS)
        popover(isPresented: isPresented) {
            content()
        }
        #else
        self
        #endif
    }
}
