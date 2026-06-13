import Domain
import SwiftUI

/// Footnote subtitle under the high-quality soundfont row. Its content is purely a function of the download state and
/// the opt-in flag — kept in its own struct so the `OpenURLAction` for the "download now" markdown link is allocated
/// once per subtitle instance rather than on every parent body evaluation.
struct SoundfontStateSubtitle: View {
    let downloadState: SoundfontDownloadState
    let isOptedIn: Bool
    let onDownloadNow: () -> Void

    var body: some View {
        switch downloadState {
        case .idle:
            if isOptedIn {
                // The localized value embeds a markdown link (folino-action://download-now) styled as a tinted inline
                // link. The `openURL` handler below intercepts that custom URL and routes it to the same code path the
                // "Download Now" alert button uses — bypassing the Wi-Fi gate.
                Text("settings.soundfont.state.waitingForWiFi", bundle: .module)
                    .environment(\.openURL, OpenURLAction { url in
                        if url.scheme == "folino-action", url.host == "download-now" {
                            onDownloadNow()
                            return .handled
                        }
                        return .systemAction
                    })
            }
        case .downloading, .downloaded:
            EmptyView()
        case let .failed(reason):
            Text(verbatim: String(localized: "settings.soundfont.state.failed", bundle: .module) + " (\(reason))")
                .foregroundStyle(.red)
        }
    }
}
