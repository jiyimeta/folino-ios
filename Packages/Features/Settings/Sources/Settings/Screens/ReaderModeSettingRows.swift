import Domain
import SwiftUI
import UIKit

/// Repeat-mode menu row for Settings. Mirrors the Reader playback inspector's repeat control: the mode is global /
/// sticky (shared by every score); the A–B loop's measure endpoints stay per-score and are set in the Reader, not here.
struct RepeatModeSettingRow: View {
    @Binding var mode: RepeatMode

    var body: some View {
        ReaderModeMenuRowLayout(
            titleKey: "settings.reader.repeat",
            titleSystemImage: "repeat",
            valueTitleKey: titleKey(for: mode),
            valueIcon: { icon(for: mode) },
        ) {
            Picker(selection: $mode) {
                ForEach(RepeatMode.allCases, id: \.self) { mode in
                    Label {
                        Text(titleKey(for: mode), bundle: .module)
                    } icon: {
                        icon(for: mode)
                    }
                    .tag(mode)
                }
            } label: { EmptyView() }
                .labelsHidden()
        }
    }

    private func titleKey(for mode: RepeatMode) -> LocalizedStringKey {
        switch mode {
        case .off: "settings.reader.repeat.off"
        case .loopAll: "settings.reader.repeat.loopAll"
        case .abLoop: "settings.reader.repeat.abLoop"
        }
    }

    @ViewBuilder
    private func icon(for mode: RepeatMode) -> some View {
        switch mode {
        case .off: Image(systemName: "repeat.badge.xmark")
        case .loopAll: Image(systemName: "repeat.1")
        // Custom AB asset (duplicated from the Reader bundle). Pre-rasterize to symbol scale — its large intrinsic size
        // can't be tamed by a SwiftUI `.frame` inside a menu label. Falls back to an SF Symbol if the asset is missing.
        case .abLoop:
            if let image = UIImage(named: "repeat_a_b", in: .module, with: nil) {
                Image(uiImage: image.resized(to: CGSize(width: 16, height: 16)))
                    .renderingMode(.template)
            } else {
                Image(systemName: "repeat")
            }
        }
    }
}

/// Playlist-continuation menu row for Settings. Mirrors the inspector's continuation control: same wording and the same
/// per-option icons.
struct PlaylistContinuationSettingRow: View {
    @Binding var mode: PlaylistContinuationMode

    var body: some View {
        ReaderModeMenuRowLayout(
            titleKey: "settings.reader.continuation",
            titleSystemImage: "music.note.list",
            footerKey: "settings.reader.continuation.footer",
            valueTitleKey: titleKey(for: mode),
            valueIcon: { icon(for: mode) },
        ) {
            Picker(selection: $mode) {
                ForEach(PlaylistContinuationMode.allCases, id: \.self) { mode in
                    Label {
                        Text(titleKey(for: mode), bundle: .module)
                    } icon: {
                        icon(for: mode)
                    }
                    .tag(mode)
                }
            } label: { EmptyView() }
                .labelsHidden()
        }
    }

    private func titleKey(for mode: PlaylistContinuationMode) -> LocalizedStringKey {
        switch mode {
        case .off: "settings.reader.continuation.off"
        case .playThrough: "settings.reader.continuation.playThrough"
        case .loopPlaylist: "settings.reader.continuation.loopPlaylist"
        }
    }

    @ViewBuilder
    private func icon(for mode: PlaylistContinuationMode) -> some View {
        switch mode {
        case .off: Image(systemName: "pause")
        case .playThrough: Image(systemName: "forward.end")
        case .loopPlaylist: Image(systemName: "repeat")
        }
    }
}

/// Shared layout for the two reader-mode rows: a width-priority leading title (icon + text) and a trailing menu whose
/// selected value sits inline (accent-tinted, truncating to one line so it never wraps on small screens / large type).
private struct ReaderModeMenuRowLayout<ValueIcon: View, MenuContent: View>: View {
    let titleKey: LocalizedStringKey
    let titleSystemImage: String
    /// Optional secondary line shown on its own row beneath the title+menu (aligned under the title text), matching the
    /// toggle rows that carry an inline footnote. Kept off the title row so the trailing menu value never truncates.
    /// `nil` keeps the row a single title line.
    var footerKey: LocalizedStringKey?
    let valueTitleKey: LocalizedStringKey
    @ViewBuilder let valueIcon: () -> ValueIcon
    @ViewBuilder let menuContent: () -> MenuContent

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label {
                    Text(titleKey, bundle: .module)
                } icon: {
                    Image(systemName: titleSystemImage)
                }
                .layoutPriority(1)
                Spacer(minLength: 8)
                Menu {
                    menuContent()
                } label: {
                    HStack(spacing: 4) {
                        valueIcon()
                        Text(valueTitleKey, bundle: .module)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Image(systemName: "chevron.up.chevron.down")
                            .imageScale(.small)
                    }
                    .foregroundStyle(Color.accentColor)
                }
            }
            if let footerKey {
                Label {
                    Text(footerKey, bundle: .module)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } icon: {
                    // Invisible placeholder so the description aligns under the title text, not under the icon. The
                    // Label keeps the ambient (body) font, so this hidden icon matches the title row's icon width.
                    Image(systemName: titleSystemImage)
                        .hidden()
                }
            }
        }
    }
}

extension UIImage {
    func resized(to size: CGSize) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
