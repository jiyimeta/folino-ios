import SwiftUI

/// The score-domain glyphs SF Symbols has no equivalent for, as symbol assets in this module's catalog.
///
/// They live here rather than in whichever Feature drew one first because the same idea turns up in more than one:
/// a Feature cannot reach another Feature's bundle, and `Image(_:bundle:)` needs the bundle of the module that
/// *defines* the asset. Accessors rather than exported string ids, so a caller cannot get the pairing wrong.
public enum ScoreSymbol {
    /// A sharp beside a flat — "the written pitch moves". Shared by the Reader's transpose row and the editing
    /// strip's key-signature entry: changing the key and transposing are the same idea to a reader, so they read
    /// as the same glyph.
    public static var sharpFlat: Image {
        Image("sharp.flat", bundle: .module)
    }

    /// Two stacked digits — a time signature as it is engraved. SF Symbols has no meter glyph, and a `Menu` row's
    /// `Label` only renders an `Image` for its icon (an arbitrary view is dropped), so a runtime `VStack` of two
    /// `Text`s could not stand in for one.
    ///
    /// The digits are drawn a little wider than a proportional half-height scale, so each still reads as a numeral
    /// rather than as a squeezed line at the size a menu row draws it.
    public static var timeSignature: Image {
        Image("time.signature", bundle: .module)
    }
}

#Preview("Score symbols") {
    Form {
        ForEach([Font.Weight.ultraLight, .regular, .semibold, .black], id: \.self) { weight in
            LabeledContent {
                HStack(spacing: 20) {
                    ScoreSymbol.sharpFlat
                    ScoreSymbol.timeSignature
                }
                .font(.system(size: 22, weight: weight))
                .foregroundStyle(Color.accentColor)
            } label: {
                Text(verbatim: "\(weight)")
            }
        }
        Label { Text(verbatim: "Key Signature") } icon: { ScoreSymbol.sharpFlat }
        Label { Text(verbatim: "Time Signature") } icon: { ScoreSymbol.timeSignature }
    }
}
