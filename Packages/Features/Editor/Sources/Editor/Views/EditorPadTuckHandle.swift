import EditorCore
import SwiftUI
import UtilityUI

#if os(macOS)
import AppKit
#endif

/// The pull tab a tucked pad leaves at the screen edge — iOS PiP's chevron tab, with a keyboard glyph added so the
/// tab says what it will bring back, not just that something is there. Drawn square against the screen edge and
/// rounded on the inner side, the same tab-against-the-edge shape the Reader's page-turn highlight uses.
///
/// The tap is a `Button`; the drag that pulls the pad out is NOT handled here. The chrome attaches its one drag
/// gesture to the whole cluster this tab is an overlay of, so a moving finger is a drag wherever it lands and a still
/// one is this button's tap — the same split the pad keys rely on.
struct EditorPadTuckHandle: View {
    /// The chrome offsets the tab by exactly its own width to hang it outside the pad's edge — keep the frame below
    /// and this constant the same number.
    static let width: CGFloat = 36

    let side: EditorPadTuckSide
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 5) {
                Image(systemName: "keyboard")
                    .font(.system(size: 15, weight: .medium))
                Image(systemName: side.chevronSystemName)
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(.primary)
            .frame(width: Self.width, height: 68)
            // The whole tab is the touch target, not the glyphs' opaque pixels. Without this the tab was
            // untouchable in practice: `glassEffect` is an effect, not content, so it contributes no hit-testable
            // geometry, and a bare `.frame`'s empty space doesn't hit-test either — on device every tap and drag
            // fell through the tab onto the score while the glass shimmered. (`.buttonStyle(.plain)` made it worse
            // by shrinking the button's own region the same way; the default style + tint matches the other chrome
            // controls and takes the full label.)
            .contentShape(Rectangle())
        }
        .tint(.primary)
        .interactiveGlassCompat(in: shape)
        .shadow(color: .gray.opacity(0.3), radius: 10, y: 5)
        .accessibilityLabel(Text("editor.chrome.showPad", bundle: .module))
    }

    /// Rounded only on the side facing the screen; the edge side stays square so the tab reads as tucked against the
    /// edge rather than floating beside it.
    private var shape: UnevenRoundedRectangle {
        let radius: CGFloat = 14
        return switch side {
        case .trailing:
            UnevenRoundedRectangle(cornerRadii: RectangleCornerRadii(
                topLeading: radius, bottomLeading: radius, bottomTrailing: 0, topTrailing: 0,
            ))
        case .leading:
            UnevenRoundedRectangle(cornerRadii: RectangleCornerRadii(
                topLeading: 0, bottomLeading: 0, bottomTrailing: radius, topTrailing: radius,
            ))
        }
    }
}

// PARITY(macos): pad-tuck-handle preview background — `.systemGroupedBackground` has no macOS analogue, so the
//   preview stands in with `.windowBackgroundColor`. Still provisional: the Reader's Mac port landed and settled a
//   reading DESK (`MacReaderGround`), which is not a grouped-list surface, so the question of what a Mac grouped
//   surface should read as is open and falls to whoever builds the first one — the Mac pad itself, in Ⅳ.
#if os(iOS)
private let previewBackground = Color(uiColor: .systemGroupedBackground)
#else
private let previewBackground = Color(nsColor: .windowBackgroundColor)
#endif

#Preview("Handle · both sides") {
    HStack {
        EditorPadTuckHandle(side: .leading, onTap: {})
        Spacer()
        EditorPadTuckHandle(side: .trailing, onTap: {})
    }
    .padding(.vertical, 200)
    .background(previewBackground)
}
