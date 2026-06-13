import Domain
import SwiftUI

/// Visual body of the high-quality soundfont row: a `Label` whose title stacks the headline over a state subtitle, with
/// the morphing accessory trailing. Composes `SoundfontStateSubtitle` and `SoundfontAccessory` from narrow inputs
/// so the row's alert state lives entirely in the parent `SoundfontPresetRow`.
struct SoundfontPresetRowContent: View {
    let downloadState: SoundfontDownloadState
    let isOptedIn: Bool
    let toggleBinding: Binding<Bool>
    let onDownloadNow: () -> Void
    let onCancelDownload: () -> Void
    let onStopOptOut: () -> Void

    var body: some View {
        Label {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("settings.soundfont.highQuality.title", bundle: .module)
                    SoundfontStateSubtitle(
                        downloadState: downloadState,
                        isOptedIn: isOptedIn,
                        onDownloadNow: onDownloadNow,
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                SoundfontAccessory(
                    downloadState: downloadState,
                    isOptedIn: isOptedIn,
                    toggleBinding: toggleBinding,
                    onCancelDownload: onCancelDownload,
                    onStopOptOut: onStopOptOut,
                )
            }
        } icon: {
            Image(systemName: "pianokeys")
        }
    }
}
