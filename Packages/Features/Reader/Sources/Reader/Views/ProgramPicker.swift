import Domain
import SheetMusicAudio
import SwiftUI

/// Program override Menu for one mixer strip — a (part × distinct instrument) pair — shown on that strip's row in the
/// Reader Inspector's Playback tab. Lives outside `PlaybackInspectorScreen` so the screen file stays under length
/// limits.
///
/// `strip.isDrums` selects which catalog drives the menu: GM Level 1 melodic instruments for pitched strips, or
/// `GMDrumKit` (the kits actually shipped by the SF2 split resolver) for percussion. Drum-ness is that flag and never
/// "the strip reports no program" — since swift-sheet-music 1.12.0 a drum strip reports its KIT's program, and a nil
/// program means the metronome, which is never a strip. The override-set / reset / cache-hit-miss machinery underneath
/// is shared.
struct ProgramPicker: View {
    let mixerModel: PlaybackMixerModel
    let strip: MixerStrip

    private var isDrums: Bool {
        strip.isDrums
    }

    var body: some View {
        let program = mixerModel.effectiveProgram(for: strip.id)
        let hasOverride = mixerModel.hasProgramOverride(for: strip.id)
        Menu {
            if hasOverride {
                resetButton
                Divider()
            }
            if isDrums {
                drumKitSections
            } else {
                instrumentSections
            }
        } label: {
            HStack(spacing: 6) {
                pickerIcon
                    .foregroundStyle(.secondary)
                menuLabel(program: program)
            }
        }
        .menuIndicator(.hidden)
        .font(.caption)
        .padding(.top, 2)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var pickerIcon: some View {
        if isDrums {
            Image("snare", bundle: .module)
                .resizable()
                .scaledToFit()
                .frame(width: 14, height: 14)
        } else {
            Image(systemName: "pianokeys")
        }
    }

    private var instrumentSections: some View {
        ForEach(GMInstrument.Family.allCases, id: \.self) { family in
            Section(family.rawValue) {
                ForEach(family.programs) { instrument in
                    Button {
                        Task { await mixerModel.setProgram(Int(instrument.program), for: strip.id) }
                    } label: {
                        Text(instrument.name)
                    }
                }
            }
        }
    }

    private var drumKitSections: some View {
        ForEach(GMDrumKit.Family.allCases, id: \.self) { family in
            Section(family.rawValue) {
                ForEach(family.kits) { kit in
                    Button {
                        Task { await mixerModel.setProgram(Int(kit.program), for: strip.id) }
                    } label: {
                        Text(kit.name)
                    }
                }
            }
        }
    }

    private var resetButton: some View {
        Button {
            Task { await mixerModel.clearProgramOverride(for: strip.id) }
        } label: {
            Label {
                Text("reader.preferences.resetDefault", bundle: .module)
            } icon: {
                Image(systemName: "arrow.uturn.backward")
            }
        }
    }

    private func menuLabel(program: Int) -> some View {
        HStack(spacing: 4) {
            Text(displayName(for: program))
                .lineLimit(1)
                .truncationMode(.tail)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func displayName(for program: Int) -> String {
        let byte = UInt8(clamping: program)
        if isDrums {
            return GMDrumKit.kit(for: byte)?.name ?? "Kit \(program)"
        }
        return GMInstrument.instrument(for: byte).name
    }
}
