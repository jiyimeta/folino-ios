// PARITY(android): drum note entry pad — Android needs a Compose pad over the same `EditorCore` ops
//   (`pressDrumKey`, `DrumPadLayout`, `litDrumPitches`, the column caret). Only this view is iOS-only; every
//   decision behind it is in `EditorCore`, which `FolinoEditorJNI` already links, so implementing the Compose half
//   moves no logic.
import EditorCore
import SwiftUI
import UtilityUI

/// The pad's lower rows when the caret is on a percussion staff: the drum kit instead of the pitch letters
/// (drum note entry's §5.3).
///
/// Row 1 of the pad is untouched — same durations, tuplet, tie and dot keys, same behavior — and the rest key keeps
/// its pitched meaning at the end of the last row. What changes is only which instruments the middle rows write.
struct EditorDrumPadRows: View {
    let layout: DrumPadLayout
    let litPitches: Set<Int>
    let isFlexible: Bool
    let press: (DrumPadKey) -> Void
    /// The rest key, handed in whole so this view does not need to know what the pad's other rows are made of.
    /// It closes the FIRST row, opposite the menu, so the two keys that are not instruments bracket the kit rather
    /// than crowding one end of it.
    let restKey: AnyView
    /// The menu of drums this layout leaves off, closing the last row.
    let moreKey: AnyView

    var body: some View {
        ForEach(Array(rows.enumerated()), id: \.offset) { index, keys in
            HStack(spacing: 4) {
                ForEach(keys) { key in
                    EditorDrumPadKeyButton(
                        key: key,
                        label: shellLabels[key.pitch],
                        isLit: litPitches.contains(key.pitch),
                        isFlexible: isFlexible,
                        press: press,
                    )
                }
                if index == 0 {
                    restKey
                }
                if index == rows.count - 1 {
                    moreKey
                }
            }
        }
    }

    /// The one- or two-letter mark that separates drums drawn with the same picture, worked out from what the pad
    /// actually holds rather than hardcoded: the four rack toms share one drawing and the two floor toms another,
    /// so a letter is information only when more than one of a kind is on the pad. The default layout has one floor
    /// tom, which is why it wears nothing.
    private var shellLabels: [Int: String] {
        let families = [[50: "H", 48: "HM", 47: "M", 45: "L"], [43: "H", 41: "L"]]
        var labels: [Int: String] = [:]
        for family in families {
            let present = layout.keys.map(\.pitch).filter { family[$0] != nil }
            guard present.count > 1 else { continue }
            for pitch in present {
                labels[pitch] = family[pitch]
            }
        }
        return labels
    }

    /// The keys split across `layout.rowCount` rows, the earlier rows taking the extra key when the split is
    /// uneven — a row that is one key longer reads better at the top than at the bottom, where the rest key
    /// already makes the last row wider.
    private var rows: [[DrumPadKey]] {
        guard layout.rowCount > 1, !layout.keys.isEmpty else { return [layout.keys] }
        let perRow = Int(ceil(Double(layout.keys.count) / Double(layout.rowCount)))
        return stride(from: 0, to: layout.keys.count, by: perRow).map {
            Array(layout.keys[$0 ..< min($0 + perRow, layout.keys.count)])
        }
    }
}

/// One instrument key: its notehead over a short name, a voice badge when it is not in voice 1, and lit while its
/// instrument sounds in the caret's column.
///
/// Lit is what makes the pad readable while correcting an imported chart, and it is the property that lets the keys
/// be toggles at all: a lit key means "this is here", so pressing it takes it away.
struct EditorDrumPadKeyButton: View {
    let key: DrumPadKey
    /// The letter on the drum's shell, for the toms the pad holds more than one of. Nil everywhere else.
    var label: String?
    let isLit: Bool
    let isFlexible: Bool
    let press: (DrumPadKey) -> Void

    /// How tall the pictogram is drawn inside the 44 pt key. The rest is breathing room; on a phone the icon
    /// narrows further because the keys share the row's width, which is why it is a maximum and not a size.
    private static let iconHeight: CGFloat = 34

    var body: some View {
        Button {
            press(key)
        } label: {
            face
                .padKeyChrome(isArmed: isLit, isFlexible: isFlexible)
        }
        .tint(.primary)
        .accessibilityLabel(Text(DrumKeyLabel.name(for: key)))
        .accessibilityAddTraits(isLit ? [.isSelected] : [])
    }

    /// The pictogram for the instrument, or — for a drum nothing is drawn for, which a user-edited layout can hold
    /// — the notehead-and-name face the pad wore before the icons existed.
    @ViewBuilder private var face: some View {
        if let icon = DrumInstrumentIcon.forPitch(key.pitch) {
            DrumInstrumentIconView(icon: icon, label: label)
                .frame(
                    maxWidth: isFlexible ? .infinity : Self.iconHeight,
                    maxHeight: Self.iconHeight,
                )
                .overlay(alignment: .topTrailing) { voiceBadge }
        } else {
            legacyFace
        }
    }

    private var legacyFace: some View {
        VStack(spacing: 1) {
            EditorDrumNoteheadGlyph(headType: key.headType)
            Text(DrumKeyLabel.short(for: key))
                .font(.system(size: 9, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .overlay(alignment: .topTrailing) { voiceBadge }
    }

    @ViewBuilder private var voiceBadge: some View {
        if key.voiceIndex > 0 {
            Text(verbatim: "\(key.voiceIndex + 1)")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }
}

/// The notehead a key writes, drawn as the key's own glyph.
///
/// Deliberately shapes rather than SMuFL: the key face is 12 pt tall and a notehead glyph rendered at that size is
/// a smudge, while the three shapes that actually distinguish a kit — round, cross, slashed — read at any size.
struct EditorDrumNoteheadGlyph: View {
    let headType: String?

    var body: some View {
        switch headType {
        case "cross":
            Image(systemName: "multiply")
                .font(.system(size: 11, weight: .bold))
        case "slash", "slashed1", "slashed2":
            Image(systemName: "line.diagonal")
                .font(.system(size: 12, weight: .bold))
        case "diamond":
            Image(systemName: "diamond")
                .font(.system(size: 10, weight: .semibold))
        default:
            Image(systemName: "oval.fill")
                .font(.system(size: 9))
        }
    }
}

/// What a drum key is called, on its face and to VoiceOver.
///
/// Localized HERE rather than in `EditorCore`: `String(localized:)` needs an xcstrings bundle, and the core has to
/// cross into an Android `.so`. Android assembles the same labels from its own string resources under the same
/// `editor.drum.*` keys. A pitch with no entry of its own falls back to the GM name the key carries, which is
/// English — better than an empty key face, and only reachable for an instrument the layout editor put there.
enum DrumKeyLabel {
    static func short(for key: DrumPadKey) -> String {
        shortKeys[key.pitch].map { String(localized: String.LocalizationValue($0), bundle: .module) } ?? key.name
    }

    static func name(for key: DrumPadKey) -> String {
        nameKeys[key.pitch].map { String(localized: String.LocalizationValue($0), bundle: .module) } ?? key.name
    }

    private static let shortKeys: [Int: String] = [
        35: "editor.drum.short.bassDrum", 36: "editor.drum.short.bassDrum",
        37: "editor.drum.short.sideStick", 38: "editor.drum.short.snare",
        39: "editor.drum.short.handClap", 40: "editor.drum.short.snare",
        41: "editor.drum.short.floorTomLow", 42: "editor.drum.short.hiHatClosed",
        43: "editor.drum.short.floorTomHigh", 44: "editor.drum.short.hiHatPedal",
        45: "editor.drum.short.tomLow", 46: "editor.drum.short.hiHatOpen",
        47: "editor.drum.short.tomMid", 48: "editor.drum.short.tomHiMid",
        49: "editor.drum.short.crash", 50: "editor.drum.short.tomHigh",
        51: "editor.drum.short.ride", 52: "editor.drum.short.chinese",
        53: "editor.drum.short.rideBell", 54: "editor.drum.short.tambourine",
        55: "editor.drum.short.splash", 56: "editor.drum.short.cowbell",
        57: "editor.drum.short.crash2", 58: "editor.drum.short.vibraslap",
        59: "editor.drum.short.ride2", 60: "editor.drum.short.bongoHigh",
        61: "editor.drum.short.bongoLow",
    ]

    private static let nameKeys: [Int: String] = shortKeys.mapValues {
        $0.replacingOccurrences(of: "editor.drum.short.", with: "editor.drum.name.")
    }
}

#if DEBUG
import Domain

extension PreviewEditorFactory {
    /// A view model opened on a one-bar drum staff with the caret on beat 1 — what the drum previews below
    /// need, and the shape the pad decides its lower rows from.
    @MainActor
    static func makeDrumViewModel(withHits hits: [Int] = []) -> EditorViewModel {
        let viewModel = makeViewModel(armedDuration: .eighth)
        let voice = Voice(elements: [
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .rest(duration: .quarter), .rest(duration: .quarter),
            .rest(duration: .quarter), .rest(duration: .quarter),
        ])
        let bar = Measure(voices: [voice])
        let staff = Staff(
            staffType: GMPercussion.staffTypeName,
            group: GMPercussion.staffGroup,
            measures: [bar],
        )
        let part = Part(
            id: "1",
            instrument: Instrument(id: "drumset", useDrumset: true, drumLineMap: GMPercussion.drumLineMap),
            staves: [staff],
        )
        viewModel.beginSession(score: Score(division: 480, parts: [part]))
        viewModel.select(.rest(RestID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
            measureIndex: 0, voiceIndex: 0, elementIndex: 1,
        )))
        for pitch in hits {
            if let key = DrumPadKey(gmPitch: pitch) {
                viewModel.pressDrumKey(key)
            }
        }
        return viewModel
    }
}

#Preview("drum pad · compact") {
    VStack {
        Spacer()
        EditorPadView(viewModel: PreviewEditorFactory.makeDrumViewModel())
    }
    .frame(width: 390)
    .background(Color.gray.opacity(0.15))
    .environment(\.horizontalSizeClass, .compact)
}

// The lit state — a hi-hat and a snare sounding in the caret's column — which is what makes the pad readable
// while correcting an imported chart.
#Preview("drum pad · lit") {
    VStack {
        Spacer()
        EditorPadView(viewModel: PreviewEditorFactory.makeDrumViewModel(withHits: [42, 38]))
    }
    .frame(width: 390)
    .background(Color.gray.opacity(0.15))
    .environment(\.horizontalSizeClass, .compact)
}

#Preview("drum pad · regular") {
    VStack {
        Spacer()
        EditorPadView(viewModel: PreviewEditorFactory.makeDrumViewModel())
    }
    .frame(width: 900)
    .background(Color.gray.opacity(0.15))
    .environment(\.horizontalSizeClass, .regular)
}
#endif
