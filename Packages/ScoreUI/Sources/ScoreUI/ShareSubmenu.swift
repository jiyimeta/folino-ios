import Domain
import SwiftUI
import UtilityUI

/// Lazy-loading share submenu. Shows the placeholder formats (no `isOriginal` flag) until the menu first opens, then
/// fetches the per-item options once via `loadFormats` and updates the rows in place. Loading on first open avoids
/// parsing every score in a large list at row-appear time.
@MainActor
public struct ShareSubmenu: View {
    let loadFormats: @Sendable () async -> [ScoreShareFormatOption]
    let onShare: (ScoreShareFormat) -> Void

    @State private var options: [ScoreShareFormatOption] = ShareSubmenu.placeholderFormats
    @State private var hasLoaded = false

    public init(
        loadFormats: @escaping @Sendable () async -> [ScoreShareFormatOption],
        onShare: @escaping (ScoreShareFormat) -> Void,
    ) {
        self.loadFormats = loadFormats
        self.onShare = onShare
    }

    public var body: some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button {
                    onShare(option.format)
                } label: {
                    shareMenuLabel(option: option)
                }
            }
            // Triggers exactly when the menu opens. The empty view disappears when the menu closes, cancelling the task
            // — the `hasLoaded` flag stops the next open from refetching.
            Color.clear.frame(width: 0, height: 0)
                .task {
                    guard !hasLoaded else { return }
                    options = await loadFormats()
                    hasLoaded = true
                }
        } label: {
            Label {
                L10n.Common.share
            } icon: {
                Image(systemName: "square.and.arrow.up")
            }
        }
    }

    static let placeholderFormats: [ScoreShareFormatOption] = [
        ScoreShareFormatOption(format: .museScoreV4),
        ScoreShareFormatOption(format: .museScoreV3),
        ScoreShareFormatOption(format: .pdf),
        ScoreShareFormatOption(format: .midi),
        ScoreShareFormatOption(format: .audioM4A),
    ]
}

@MainActor
private func shareMenuLabel(option: ScoreShareFormatOption) -> some View {
    Label {
        shareMenuTitle(for: option)
    } icon: {
        Image(systemName: shareMenuIconName(for: option.format))
    }
}

@MainActor
@ViewBuilder
private func shareMenuTitle(for option: ScoreShareFormatOption) -> some View {
    let formatText = shareMenuFormatText(for: option.format)
    if option.isOriginal {
        // Mark the option that matches the source's format so the user can tell it from re-encoded peers.
        formatText
            + Text(verbatim: " ")
            + Text("scoreUI.format.original.suffix", bundle: .module)
    } else {
        formatText
    }
}

private func shareMenuFormatText(for format: ScoreShareFormat) -> Text {
    switch format {
    case .museScoreV4:
        Text("scoreUI.format.musescore4", bundle: .module)
    case .museScoreV3:
        Text("scoreUI.format.musescore3", bundle: .module)
    case .pdf:
        Text("scoreUI.format.pdf", bundle: .module)
    case .midi:
        Text("scoreUI.format.midi", bundle: .module)
    case .audioM4A:
        Text("scoreUI.format.m4a", bundle: .module)
    }
}

private func shareMenuIconName(for format: ScoreShareFormat) -> String {
    switch format {
    case .museScoreV4, .museScoreV3:
        "doc.zipper"
    case .pdf:
        "doc.richtext"
    case .midi:
        "pianokeys"
    case .audioM4A:
        "waveform"
    }
}
