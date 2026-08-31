import Domain
import SwiftUI
import UtilityUI

struct RepeatModePicker: View {
    @Binding var selection: RepeatMode

    var body: some View {
        Menu {
            Picker("", selection: $selection) {
                ForEach(RepeatMode.allCases, id: \.self) { mode in
                    Label {
                        Text(titleKey(for: mode), bundle: .module)
                    } icon: {
                        icon(for: mode)
                    }
                    .tag(mode)
                }
            }
            .labelsHidden()
        } label: {
            // Self-built label (rather than a `.menu`-style `Picker`) so the selected value can truncate to one line —
            // a `.menu` Picker ignores `lineLimit` on its inline value and wraps it on cramped layouts.
            InspectorMenuValueLabel {
                icon(for: selection)
            } title: {
                Text(titleKey(for: selection), bundle: .module)
            }
        }
    }

    private func titleKey(for mode: RepeatMode) -> LocalizedStringKey {
        switch mode {
        case .off: "reader.repeat.off"
        case .loopAll: "reader.repeat.loopAll"
        case .abLoop: "reader.repeat.abLoop"
        }
    }

    @ViewBuilder
    private func icon(for mode: RepeatMode) -> some View {
        switch mode {
        case .off: Image(systemName: "repeat.badge.xmark")
        case .loopAll: Image(systemName: "repeat.1")
        // Custom asset (no SF Symbol for A–B). Its large intrinsic size can't be tamed by a SwiftUI `.frame` in a menu
        // label, so pre-rasterize it to symbol scale and keep it a template so it tints like the others.
        case .abLoop: abLoopIcon.renderingMode(.template)
        }
    }

    // PARITY(macos): `repeatAB` is an iOS-only asset-catalog member (no SF Symbol matches it either), so this falls
    //   back to a stand-in system symbol on macOS. Ⅳ's Mac reading surface should add a macOS-enabled asset when it
    //   builds this control for real.
    private var abLoopIcon: Image {
        #if os(iOS)
        let rasterized = PlatformImage(resource: .repeatAB).resized(to: CGSize(width: 16, height: 16))
        return Image(uiImage: rasterized)
        #else
        return Image(systemName: "arrow.triangle.2.circlepath")
        #endif
    }
}

extension PlatformImage {
    func resized(to size: CGSize) -> PlatformImage {
        #if os(iOS)
        UIGraphicsImageRenderer(size: size).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
        #else
        let resized = NSImage(size: size)
        resized.lockFocus()
        draw(in: CGRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
        resized.unlockFocus()
        return resized
        #endif
    }
}

/// Inline label for the inspector's menu controls (repeat / playlist continuation): a leading icon, the selected value,
/// and a trailing menu chevron. The value truncates to one line so it never wraps on small screens or large Dynamic
/// Type; the row title (laid out beside this label) keeps width priority.
struct InspectorMenuValueLabel<Icon: View, Title: View>: View {
    @ViewBuilder let icon: () -> Icon
    @ViewBuilder let title: () -> Title

    /// Tint like a standard menu value when active; fall back to secondary when disabled (a forced accent wouldn't dim
    /// on its own, so the disabled state would look enabled).
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 4) {
            icon()
            title()
                .lineLimit(1)
                .truncationMode(.tail)
            Image(systemName: "chevron.up.chevron.down")
                .imageScale(.small)
        }
        .foregroundStyle(isEnabled ? Color.accentColor : Color.secondary)
    }
}

#Preview {
    RepeatModePicker(selection: .constant(.abLoop))
}
