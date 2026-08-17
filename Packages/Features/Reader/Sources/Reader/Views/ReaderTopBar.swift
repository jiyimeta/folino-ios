import SwiftUI
import UtilityUI

/// The Reader's top strip. Hosts whatever controls belong on screen right now — the Reader's own, or the editing row
/// the App injects — and owns the height both cases have to agree on.
///
/// The control tier is attached with `safeAreaInset(edge: .top)`, so the score's safe area accounts for it without
/// any call site subtracting a constant. **It carries no `padding(.top:)` and no `ignoresSafeArea`.** The system's
/// own top inset is already below the strip's content; adding the safe-area height back as padding would count it
/// twice, and `ignoresSafeArea` on a fixed-height child shifts it rather than extending it.
///
/// The height is read from `ReaderTopBarLayout.contributedInset(topSafeAreaInset:isEditing:)` — the same contract
/// function `ReaderTopBarLayoutTests` pins — rather than `controlTierHeight` directly, so this, the production call
/// site, and the test all agree on ONE source. Reading the raw constant here would let the two drift silently: the
/// test would still pass if this view's actual height diverged from what the contract promises (an `if isEditing`
/// branch, a stray `.padding(.vertical)`, a `safeAreaInset(spacing:)` other than the default), because nothing
/// would ever call the contract function with the values THIS view actually uses.
struct ReaderTopBar<Content: View>: View {
    /// Forwarded straight into `ReaderTopBarLayout.contributedInset` — see that function's own doc comment for why
    /// the contract takes parameters it then ignores: a signature that took nothing would make the invariant
    /// unfalsifiable.
    var topSafeAreaInset: CGFloat = 0
    var isEditing = false
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(.horizontal)
            .frame(maxWidth: .infinity)
            .frame(height: ReaderTopBarLayout.contributedInset(
                topSafeAreaInset: topSafeAreaInset,
                isEditing: isEditing,
            ))
    }
}

/// The tier drawn inside the top safe area, flanking the display cutout. An overlay rather than a `safeAreaInset`
/// precisely so it contributes nothing: the band it occupies is reserved by the system either way.
///
/// The two clusters are pinned to their own edges and nothing is placed in the middle — the cutout's width varies by
/// model and is not ours to know.
struct ReaderCutoutTier<Leading: View, Trailing: View>: View {
    let topSafeAreaInset: CGFloat
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack {
            leading
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal)
        .frame(height: topSafeAreaInset, alignment: .center)
        .frame(maxWidth: .infinity, alignment: .top)
    }
}

/// A small "PDF" pill shown when the open item is a fixed-layout PDF. The text is a brand literal and is
/// intentionally not localized (iOS/Android parity). Pure view (no `ReaderViewModel`), so it lives here rather than
/// alongside `ReaderTopBarControls` in `Screens/`.
struct PDFBadge: View {
    var body: some View {
        Text(verbatim: "PDF")
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.secondary.opacity(0.18), in: Capsule())
            .foregroundStyle(.secondary)
            .accessibilityLabel(Text(verbatim: "PDF"))
    }
}

#if DEBUG
#Preview("ReaderTopBar") {
    ReaderTopBar {
        HStack {
            Image(systemName: "chevron.backward")
            Spacer()
            Image(systemName: "slider.vertical.3")
            Image(systemName: "text.page")
        }
        .padding(.horizontal, 8)
    }
    .background(Color(white: 0.97))
}

#Preview("ReaderCutoutTier") {
    ReaderCutoutTier(topSafeAreaInset: 59) {
        Image(systemName: "xmark")
    } trailing: {
        Text(verbatim: "Revert")
    }
    .background(Color(white: 0.97))
}
#endif
