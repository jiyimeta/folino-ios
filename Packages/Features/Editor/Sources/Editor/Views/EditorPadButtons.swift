import Domain
import SwiftUI

#if os(iOS)
import UIKit
#endif

// PARITY(macos): dotted-duration menu glyph — iOS rasterizes because a UIKit `Menu` row will not draw a custom
//   View or apply a custom font. AppKit menus have no such restriction, so the Mac pad should draw the glyph as a
//   View rather than port the rasterizer.

/// Shared press feedback for every key on `EditorPadView`'s bottom pad: a brief scale-up + dim on touch-down, mirrored
/// from the Reader transport's `TransportButtonStyle` (scale `1.12`, dim to `0.7`, `.snappy(duration: 0.27)`) so the
/// pad's touch feel matches the rest of the chrome. Duration keys additionally pass `isArmed: true` for the key whose
/// duration matches `EditorViewModel.armedDuration`, drawing a persistent accent capsule behind the glyph — independent
/// of press state — so the armed duration reads at a glance.
struct PadKeyStyle: ButtonStyle {
    var isArmed = false
    /// Compact rows pack ten keys across (C–B, ▴▾, delete). A fixed 40 pt minimum made that row wider than any
    /// iPhone, so those keys instead share the row's width — `maxWidth: .infinity` can't overflow, and the 44 pt
    /// height keeps each key comfortably tappable. The iPad row has the room, so it keeps the fixed minimum.
    var isFlexible = false

    func makeBody(configuration: Configuration) -> some View {
        Key(configuration: configuration, isArmed: isArmed, isFlexible: isFlexible)
    }

    /// Named `Key`, not `Body`: a nested type called `Body` binds `ButtonStyle`'s `associatedtype Body` instead of
    /// letting `some View` infer it, and a private one then fails "must be as accessible as its enclosing type".
    private struct Key: View {
        let configuration: Configuration
        let isArmed: Bool
        let isFlexible: Bool

        var body: some View {
            configuration.label
                // Enabled/disabled colouring lives in `padKeyChrome`, not here, so the keys that can't be a Button
                // (the tuplet and dot Menus) get exactly the same treatment.
                    .padKeyChrome(isArmed: isArmed, isFlexible: isFlexible)
                    .scaleEffect(configuration.isPressed ? 1.12 : 1)
                    .opacity(configuration.isPressed ? 0.7 : 1)
                    .animation(.snappy(duration: 0.27), value: configuration.isPressed)
        }
    }
}

extension View {
    /// A pad key's size, armed capsule, and enabled/disabled colour — everything except the press feedback. Split out
    /// of `PadKeyStyle` so the keys that can't be a plain `Button` — the tuplet and dot keys are `Menu`s, which
    /// ignore `buttonStyle` — measure and read as part of the same row.
    func padKeyChrome(isArmed: Bool = false, isFlexible: Bool = false) -> some View {
        modifier(PadKeyChrome(isArmed: isArmed, isFlexible: isFlexible))
    }
}

/// Why this is a `ViewModifier` and not a few inline modifiers: it has to read `\.isEnabled`, and the two places that
/// need it can't. `ButtonStyle.makeBody` isn't a view body, so `@Environment` never updates there; a `Menu`'s label
/// closure is a plain view builder with no style hook at all.
///
/// The colour is stated outright in both directions rather than left to inheritance. A custom `ButtonStyle` opts its
/// button out of the dimming SwiftUI gives stock ones, so a disabled key stayed fully lit — while an enabled key
/// whose label happened to inherit a tint (the tie key's) sat washed-out next to keys that hadn't. Pinning enabled to
/// `.primary` and disabled to `.tertiary` makes "can I press this" the only thing the key's colour ever means.
private struct PadKeyChrome: ViewModifier {
    let isArmed: Bool
    let isFlexible: Bool
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content
            .foregroundStyle(isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            // `tint` as well as `foregroundStyle`, because a `Menu` re-applies its own tint to the label it is handed
            // — which is why the dot key's dots came out accent-blue while the duration keys beside them were black.
            .tint(isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            .frame(maxWidth: isFlexible ? .infinity : nil)
            .frame(minWidth: isFlexible ? nil : 40, minHeight: 44)
            .contentShape(Rectangle())
            .background {
                if isArmed {
                    Capsule().fill(Color.accentColor.opacity(isEnabled ? 0.25 : 0.12))
                }
            }
            .animation(.snappy(duration: 0.2), value: isEnabled)
    }
}

/// One duration key, shared by the pad's row and the callout's tray — same glyph, same capsule, same size. What it
/// MEANS differs by where it sits, so the target comes in from the caller: on the pad a length key arms the next
/// note, in the callout it re-times the selected one. Keeping the button itself identical is the point; the two
/// surfaces have to look like one control set even when they act on different things.
struct PadDurationKey: View {
    let duration: NoteDuration
    let glyph: String
    let isSelected: Bool
    var isFlexible = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            PadKeyGlyph.duration(glyph)
        }
        .buttonStyle(PadKeyStyle(isArmed: isSelected, isFlexible: isFlexible))
        .accessibilityLabel(PadDurationKey.label(duration))
    }

    /// Duration accessibility labels, kept as `LocalizedStringKey` literals so `xcstringstool` keeps extracting them.
    static func label(_ duration: NoteDuration) -> Text {
        switch duration {
        case .whole: Text("editor.duration.whole", bundle: .module)
        case .half: Text("editor.duration.half", bundle: .module)
        case .quarter: Text("editor.duration.quarter", bundle: .module)
        case .eighth: Text("editor.duration.eighth", bundle: .module)
        case .sixteenth: Text("editor.duration.sixteenth", bundle: .module)
        case .thirtySecond: Text("editor.duration.thirtySecond", bundle: .module)
        default: Text("editor.duration.sixtyFourth", bundle: .module)
        }
    }
}

/// The dot key: tap adds one augmentation dot (and a second tap clears it), hold for 1 / 2 / 3. Dots and lengths are
/// independent arms — dotted-quarter is the quarter key and this one both lit — so it never sits among the durations
/// as another mutually-exclusive choice. Shared by the pad and the callout's tray.
struct PadDotKey: View {
    let dots: Int
    var isFlexible = false
    let setDots: (Int) -> Void
    let toggle: () -> Void

    /// One, two and three dots — named the way MuseScore names them (付点 / 複付点 / 複々付点), not counted, because
    /// that is the vocabulary the notation itself uses and what a user of either app already reads.
    private static let dotChoices: [(count: Int, label: LocalizedStringKey)] = [
        (1, "editor.ops.dot.single"),
        (2, "editor.ops.dot.double"),
        (3, "editor.ops.dot.triple"),
    ]

    var body: some View {
        Menu {
            ForEach(Self.dotChoices, id: \.count) { choice in
                Button {
                    setDots(choice.count)
                } label: {
                    Label {
                        Text(choice.label, bundle: .module)
                    } icon: {
                        #if os(iOS)
                        // `Image(uiImage:)`, not the `Circle`s the key itself draws: a menu row renders text and an
                        // image, and hands anything else back as nothing at all. Rasterising the dots keeps the
                        // row's icon the same mark as the key's.
                        Image(uiImage: PadDotKey.dotsImage(count: choice.count))
                        #else
                        // AppKit `Menu` rows draw a custom `View` icon without restriction, so the Mac path skips
                        // the rasterizer and reuses the same font-drawn dots the key itself shows.
                        PadKeyGlyph.dots(choice.count)
                        #endif
                    }
                }
            }
        } label: {
            PadKeyGlyph.dots(dots)
                .padKeyChrome(isArmed: dots > 0, isFlexible: isFlexible)
        } primaryAction: {
            toggle()
        }
        .accessibilityLabel(Text("editor.ops.dot", bundle: .module))
    }

    #if os(iOS)
    /// `count` filled dots in a row, as a template image the menu can tint. Cached because a menu rebuilds its rows
    /// on every open and there are only ever three of these.
    private static func dotsImage(count: Int) -> UIImage {
        if let cached = imageCache[count] {
            return cached
        }
        let diameter: CGFloat = 4
        let gap: CGFloat = 3
        let width = CGFloat(count) * diameter + CGFloat(count - 1) * gap
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: diameter)).image { context in
            UIColor.label.setFill()
            for index in 0 ..< count {
                context.cgContext.fillEllipse(in: CGRect(
                    x: CGFloat(index) * (diameter + gap), y: 0, width: diameter, height: diameter,
                ))
            }
        }.withRenderingMode(.alwaysTemplate)
        imageCache[count] = image
        return image
    }

    @MainActor private static var imageCache: [Int: UIImage] = [:]
    #endif
}

/// Glyph builders shared by the pad's keys, kept in one place so every key group's font/weight stays in sync.
enum PadKeyGlyph {
    /// Duration key glyph — a SMuFL note drawn with the score's own Bravura font (see `PadDurationGlyph`, which owns
    /// the codepoints and the family name). Bravura's note glyphs sit on the baseline with the stem rising above it,
    /// so the whole row lines up on its noteheads; 20 pt keeps the tallest (64th, stem + four flags) inside the
    /// 44 pt key.
    static func duration(_ symbol: String) -> some View {
        Text(verbatim: symbol)
            .font(PadDurationGlyph.swiftUIFont(size: durationSize))
            // Cut the music font's enormous ascent/descent off the line box — see `PadDurationGlyph.lineTrim`.
            .padding(.top, -durationTrim.top)
            .padding(.bottom, -durationTrim.bottom)
    }

    private static let durationSize: CGFloat = 20
    private static let durationTrim = PadDurationGlyph.lineTrim(size: durationSize)

    /// Rest key glyph — the rest the key writes, in the same music font as the duration keys, so the two
    /// read as one family. Trimmed against the union of ALL rest glyphs (not just this one) so the key's height
    /// doesn't jump as the armed duration changes.
    static func rest(_ duration: NoteDuration?) -> some View {
        Text(verbatim: PadDurationGlyph.rest(for: duration))
            .font(PadDurationGlyph.swiftUIFont(size: durationSize))
            .padding(.top, -restTrim.top)
            .padding(.bottom, -restTrim.bottom)
    }

    private static let restTrim = PadDurationGlyph.lineTrim(
        size: durationSize, glyphs: PadDurationGlyph.rests.map(\.glyph),
    )

    /// Tie key glyph: the music font's tie curve, optionally badged.
    ///
    /// The pad's copy takes the badge — it's one key among many and has to say what it does. The callout's copy
    /// doesn't: it only appears when a tie is possible, and it lights up when the tie is there, so it reads as the
    /// tie's state rather than as an "add" action.
    static func tie(showsAddBadge: Bool = true) -> some View {
        Text(verbatim: PadDurationGlyph.tie)
            .font(PadDurationGlyph.swiftUIFont(size: tieSize))
            .padding(.top, -tieTrim.top)
            .padding(.bottom, -tieTrim.bottom)
            .overlay(alignment: .topTrailing) {
                if showsAddBadge {
                    // The same badge the pad-toggle symbol wears — `plus.circle.fill` is the glyph SF Symbols' own
                    // `*.badge.plus` symbols draw — so "this one adds" reads identically wherever it appears.
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .offset(x: 7, y: -6)
                }
            }
    }

    /// Well above the note glyphs' size, and deliberately so: `articLaissezVibrerAbove` is a thin arc about a third
    /// of an em wide, so at the duration keys' 24 pt it drew a hairline the width of a notehead and read as a smudge.
    /// Sized up it becomes a legible curve — and the trim below keeps its band, not its font size, inside the key.
    private static let tieSize: CGFloat = 54
    private static let tieTrim = PadDurationGlyph.lineTrim(size: tieSize, glyphs: [PadDurationGlyph.tie])

    /// Dot key glyph — one filled dot per armed augmentation dot, and a single one when none are armed (the key has
    /// to show what it offers even when it is off). Drawn as shapes rather than the font's `augmentationDot`, which
    /// is 0.1 em wide by design: at the pad's glyph size that is a ~1 pt speck, invisible on a key.
    static func dots(_ count: Int, size: CGFloat = 3) -> some View {
        AugmentationDots(count: count, size: size)
    }

    /// The score's own `augmentationDot`, not a `Circle`.
    ///
    /// A drawn shape kept reading as a grey speck next to the note glyphs however it was coloured: it is small, it is
    /// round, so every pixel of it is an anti-aliased edge, and inside the card's glass that softness is what shows.
    /// The music font's dot is the same mark the engraver puts after a note, rasterised by the same text pipeline as
    /// the duration keys beside it — so it picks up the same hinting and the same weight, and stops looking like a
    /// different kind of ink. `PadDurationGlyph.dotSize` is what makes it big enough to see (the glyph is 0.1 em).
    private struct AugmentationDots: View {
        let count: Int
        let size: CGFloat
        @Environment(\.isEnabled) private var isEnabled

        /// `size` is the dot's wanted diameter; the glyph is 0.1 em, so the font has to be ten times that.
        private var fontSize: CGFloat {
            size * 10
        }

        var body: some View {
            let trim = PadDurationGlyph.lineTrim(size: fontSize, glyphs: [PadDurationGlyph.augmentationDot])
            HStack(spacing: size * 0.6) {
                ForEach(0 ..< max(count, 1), id: \.self) { _ in
                    Text(verbatim: PadDurationGlyph.augmentationDot)
                        .font(PadDurationGlyph.swiftUIFont(size: fontSize))
                        .padding(.top, -trim.top)
                        .padding(.bottom, -trim.bottom)
                }
            }
            .foregroundStyle(isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
        }
    }

    /// What the callout's summary key wears: the selected note's length, dots and all, as ONE text run — see
    /// `PadDurationGlyph.textNote(for:dots:)` for why the dot has to come from the font rather than be stacked
    /// alongside in a layout container.
    static func durationSummary(_ duration: NoteDuration?, dots: Int) -> some View {
        let glyphs = PadDurationGlyph.textNote(for: duration, dots: dots)
        return Text(verbatim: glyphs)
            .font(PadDurationGlyph.swiftUIFont(size: summarySize))
            .padding(.top, -summaryTrim.top)
            .padding(.bottom, -summaryTrim.bottom)
    }

    /// The same summary key when a REST is selected: the rest's own glyph with its augmentation dots beside it.
    ///
    /// Composed in an `HStack`, which is exactly what `textNote(for:dots:)` exists to avoid for notes — and it works
    /// here for the reason it fails there. A note's engraving glyph advances by its notehead alone, so a stem or a
    /// flag overhangs anything laid out after it; a rest is the whole mark and advances by all of it, leaving the
    /// dot the clear space an engraver would give it.
    static func restSummary(_ duration: NoteDuration?, dots: Int) -> some View {
        HStack(spacing: 3) {
            rest(duration)
            if dots > 0 {
                PadKeyGlyph.dots(dots)
            }
        }
    }

    private static let summarySize: CGFloat = 20
    /// Trimmed against every note this key can show (undotted — the dot adds nothing above or below a notehead), so
    /// the key's height stays put as the selection moves between lengths.
    private static let summaryTrim = PadDurationGlyph.lineTrim(
        size: summarySize,
        glyphs: [NoteDuration.whole, .half, .quarter, .eighth, .sixteenth].map {
            PadDurationGlyph.textNote(for: $0, dots: 0)
        },
    )

    /// Pitch-letter key glyph (C…B).
    static func pitchLetter(_ letter: Character) -> some View {
        Text(verbatim: String(letter))
            .font(.system(size: 17, weight: .semibold, design: .rounded))
    }

    /// SF Symbol glyph for the octave-step and delete keys — matches the Reader overlay's 20pt medium icon size.
    static func symbol(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 20, weight: .medium))
    }
}
