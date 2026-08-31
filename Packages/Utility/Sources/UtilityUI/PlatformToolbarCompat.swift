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
    /// PARITY(macos): list reordering and deletion — the sheets that call this show no reorder handle and no
    ///   delete minus on macOS. AppKit reorders by drag with no edit mode at all, so the fix is an affordance,
    ///   not a port.
    @ViewBuilder
    public func activeEditModeCompat() -> some View {
        #if os(iOS)
        environment(\.editMode, .constant(.active))
        #else
        self
        #endif
    }
}
