import SwiftUI

/// The circle of fifths as a picker, binding `KeySignature.concertKey`.
///
/// Deliberately just the control — one `Picker` row, no section, no navigation, no dismissal. It sits in the
/// creation wizard's layout section and in the editor's key-change sheet, and each of those owns its own container
/// (the `InstrumentCatalogPicker` contract).
public struct KeySignaturePicker: View {
    /// The keys offered, in menu order: C-major center, sharps outward, then flats. All fifteen, so the two
    /// enharmonic extremes (C♭ major and C♯ major) can be written as such rather than only as their 6-accidental
    /// respellings.
    static let keys: [Int] = [0, 1, 2, 3, 4, 5, 6, 7, -1, -2, -3, -4, -5, -6, -7]

    @Binding private var selection: Int

    public init(selection: Binding<Int>) {
        _selection = selection
    }

    public var body: some View {
        Picker(selection: $selection) {
            ForEach(Self.keys, id: \.self) { key in
                Text(verbatim: KeySignatureLabel.label(for: key)).tag(key)
            }
        } label: {
            Text("scoreUI.keySignature.label", bundle: .module)
        }
    }
}

/// The note-name spelling of a key signature, as "major / relative minor".
///
/// Public so a caller can caption a current value without opening the picker. Not localized, and not in the
/// xcstrings catalog: note letters and accidentals are engraving vocabulary, written the same way in every
/// language folino ships.
public enum KeySignatureLabel {
    public static func label(for concertKey: Int) -> String {
        switch concertKey {
        case 0: "C / Am"
        case 1: "G / Em"
        case 2: "D / Bm"
        case 3: "A / F♯m"
        case 4: "E / C♯m"
        case 5: "B / G♯m"
        case 6: "F♯ / D♯m"
        case 7: "C♯ / A♯m"
        case -1: "F / Dm"
        case -2: "B♭ / Gm"
        case -3: "E♭ / Cm"
        case -4: "A♭ / Fm"
        case -5: "D♭ / B♭m"
        case -6: "G♭ / E♭m"
        case -7: "C♭ / A♭m"
        default: "\(concertKey)"
        }
    }
}

#Preview {
    @Previewable @State var key = 0
    Form {
        KeySignaturePicker(selection: $key)
    }
}
