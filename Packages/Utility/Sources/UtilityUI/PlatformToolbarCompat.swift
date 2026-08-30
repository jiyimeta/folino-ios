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
}
