import SwiftUI

// PARITY(macos): toolbar placement and title display mode — these substitute neutral macOS behavior so shared
//   screens compile. Ⅲb migrates each call site to a semantic placement (.cancellationAction /
//   .confirmationAction), which is what actually earns Esc / Return key equivalents on a Mac sheet.

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
}
