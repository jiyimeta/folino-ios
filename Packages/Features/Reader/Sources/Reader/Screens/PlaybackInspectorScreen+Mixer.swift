import Domain
import ReaderInteractionCore
import SheetMusicCore
import SwiftUI
import UtilityUI

/// The per-strip mixer rows of the playback inspector. Split into its own file to keep `PlaybackInspectorScreen` under
/// the file-length budget.
///
/// A row is one mixer STRIP — a (part × distinct instrument) pair, the unit the audio engine can control separately —
/// not a staff. Most scores are one strip over one staff per part, which draws exactly as the mixer always has: a
/// single row. Anything else (a grand staff, a part that changes instrument mid-score) draws a part header over one
/// row per strip, and the header is where the staff-visibility eyes live because it is the only thing left that
/// corresponds to a SET of staves.
extension PlaybackInspectorScreen {
    /// Staff addresses for a part, used as the eye buttons' identity (stable per staff, unlike a position index).
    /// Empty when the engine's strip list names a part the displayed score doesn't have, which keeps such a strip
    /// drawable rather than trapping.
    func staffAddresses(partIndex: Int) -> [StaffAddress] {
        guard score.parts.indices.contains(partIndex) else { return [] }
        return score.parts[partIndex].staves.indices.map {
            StaffAddress(partIndex: partIndex, staffIndexInPart: $0)
        }
    }

    /// Title line for a part that draws more than one row, carrying every one of its staves' show/hide eyes.
    func partHeader(_ group: [MixerStrip].PartGroup, staves: [StaffAddress]) -> some View {
        HStack {
            Text(group.partName)
                .font(.headline)
            Spacer()
            if showsStaffVisibility {
                ForEach(Array(staves.enumerated()), id: \.element) { index, address in
                    StaffVisibilityButton(
                        layoutModel: layoutModel, address: address, staffNumber: index + 1,
                    )
                }
            }
        }
    }

    /// One mixer strip: its label (when no part header has already named it) beside the program picker, over the
    /// volume / solo / mute line. `staves` is non-empty only in the collapsed one-strip-one-staff case, where this row
    /// stands in for the part header and so carries the single eye itself.
    func stripRow(_ strip: MixerStrip, label: String?, staves: [StaffAddress]) -> some View {
        VStack {
            HStack {
                if let label {
                    Text(label)
                        .font(.headline)
                }
                ProgramPicker(mixerModel: mixerModel, strip: strip)
            }
            stripControls(strip, staves: staves)
        }
    }

    @ViewBuilder
    private func stripControls(_ strip: MixerStrip, staves: [StaffAddress]) -> some View {
        let id = strip.id
        let volumeBinding = Binding<Double>(
            get: { mixerModel.volume(for: id) },
            set: { mixerModel.setVolume($0, for: id) },
        )
        let isMuted = mixerModel.mutedStrips.contains(id)
        let isSolo = mixerModel.soloStrips.contains(id)
        let isDisabled = isMuted || !mixerModel.soloStrips.isEmpty && !isSolo
        let defaultVolume = mixerModel.defaultVolume(for: id)
        HStack {
            Image(systemName: "speaker.wave.2.fill")
                .foregroundStyle(isDisabled ? .gray.opacity(0.6) : .accentColor)

            ResettableSlider(
                value: volumeBinding,
                range: 0 ... 1,
                defaultValue: defaultVolume,
                onEditingChanged: { editing in
                    if !editing {
                        let final = volumeBinding.wrappedValue
                        ReaderHintCoordinator.shared.markUsed(.mixer)
                        Task { await mixerModel.commitVolume(final, for: id) }
                    }
                },
                onReset: {
                    ReaderHintCoordinator.shared.markUsed(.mixer)
                    Task { await mixerModel.commitVolume(defaultVolume, for: id) }
                },
            )
            .tint(isDisabled ? .gray : Color.accentColor)
            .disabled(isDisabled)

            // Every strip published to the mixer is soloable — the engine's one non-soloable channel is the metronome,
            // which is never a strip — so solo shows on every row.
            Button(String("S")) {
                ReaderHintCoordinator.shared.markUsed(.mixer)
                mixerModel.toggleSolo(id)
            }
            .fontWeight(.medium)
            .buttonStyle(CircleBorderedToggleButtonStyle(isOn: isSolo))
            .accessibilityLabel(Text("reader.inspector.staffSolo", bundle: .module))

            Button(String("M")) {
                ReaderHintCoordinator.shared.markUsed(.mixer)
                mixerModel.toggleMute(id)
            }
            .fontWeight(.medium)
            .buttonStyle(CircleBorderedToggleButtonStyle(isOn: isMuted))
            .accessibilityLabel(Text("reader.inspector.staffMute", bundle: .module))

            if showsStaffVisibility {
                ForEach(staves, id: \.self) { address in
                    StaffVisibilityButton(layoutModel: layoutModel, address: address)
                }
            }
        }
    }
}
