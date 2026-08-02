import SheetMusicCore
import SwiftUI

/// Per-staff show/hide toggle, shared by the visual and playback inspectors so the same control appears (and behaves)
/// in both. The eye glyph opens / closes with the staff's visibility, wrapped in the circular toggle style that the
/// solo / mute buttons also use.
struct StaffVisibilityButton: View {
    let layoutModel: LayoutSettingsModel
    let address: StaffAddress

    var body: some View {
        let isVisible = !layoutModel.hiddenStaves.contains(address)
        Button {
            // Retires the show/hide-parts coach mark: marked here rather than in `LayoutSettingsModel` so the model
            // stays free of UI-discovery state (and its unit tests free of `UserDefaults`).
            ReaderHintCoordinator.shared.markUsed(.staffVisibility)
            Task { await layoutModel.toggleStaff(address) }
        } label: {
            EyeIcon(isOpen: isVisible, lineWidth: 1.6)
                .frame(width: 18, height: 13)
        }
        .buttonStyle(CircleBorderedToggleButtonStyle(isOn: isVisible))
        .accessibilityLabel(Text("reader.inspector.staffVisibility", bundle: .module))
    }
}

#if DEBUG
#Preview("Staff toggles") {
    HStack(spacing: 12) {
        Button(String("S")) {}.fontWeight(.medium).buttonStyle(CircleBorderedToggleButtonStyle(isOn: true))
        Button(String("S")) {}.fontWeight(.medium).buttonStyle(CircleBorderedToggleButtonStyle(isOn: false))
        Button(String("M")) {}.fontWeight(.medium).buttonStyle(CircleBorderedToggleButtonStyle(isOn: true))
        Button(String("M")) {}.fontWeight(.medium).buttonStyle(CircleBorderedToggleButtonStyle(isOn: false))
        Button {} label: { EyeIcon(isOpen: true, lineWidth: 1.6).frame(width: 18, height: 13) }
            .buttonStyle(CircleBorderedToggleButtonStyle(isOn: true))
        Button {} label: { EyeIcon(isOpen: false, lineWidth: 1.6).frame(width: 18, height: 13) }
            .buttonStyle(CircleBorderedToggleButtonStyle(isOn: false))
    }
    .padding()
}
#endif
