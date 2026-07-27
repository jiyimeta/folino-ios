import Domain
import Foundation
import Observation
import SwiftUI
import UtilityUI

/// Bottom editing pad, composed into the Reader seam above the bottom transport's reserved clearance
/// (`ReaderTransportControl.expandedContentHeight`, 114 pt) so the two never overlap. Liquid Glass card, floating
/// over the score.
///
/// iPhone (compact width), two 44 pt rows:
///  1. the durations (whole … sixteenth), the triplet key, the tie key, and delete at the right end;
///  2. the pitch letters C–B, with ♯ / ♭ at the right end.
///
/// Stepping the selection (← / →) lives OUTSIDE the pad, in its own pill beside the transport, so it stays put when
/// the pad is re-docked and doesn't cost the pad a row.
///
/// iPad (regular width) keeps its single row with the same keys, since the palette carries the rest.
public struct EditorPadView: View {
    @Bindable private var viewModel: EditorViewModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    public init(viewModel: EditorViewModel) {
        self.viewModel = viewModel
    }

    private static let pitchLetters: [Character] = ["C", "D", "E", "F", "G", "A", "B"]
    /// Height of the dividers separating key groups on the iPad one-row layout.
    private static let dividerHeight: CGFloat = 28

    /// Compact keys share the row's width instead of claiming a fixed minimum. The pitch row is ten keys wide (C–B,
    /// ▴▾, delete); at the pad's old 40 pt minimum that row demanded ~488 pt and ran off the side of every iPhone.
    /// Flexible keys can't overflow by construction — on the narrowest supported phone (375 pt) each still lands
    /// around 29 pt wide, and the 44 pt row height keeps the touch targets tall enough to hit.
    private var usesFlexibleKeys: Bool {
        horizontalSizeClass != .regular
    }

    public var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                HStack(spacing: 6) {
                    durationKeys
                    tripletKey
                    Divider().frame(height: Self.dividerHeight)
                    pitchKeys
                    pitchStepKeys
                    Divider().frame(height: Self.dividerHeight)
                    EditorContextOps.buttons(viewModel: viewModel)
                    deleteKey
                }
            } else {
                VStack(spacing: Self.rowSpacing) {
                    // Delete anchors the right end of the first row, as far as the row allows from the pitch letters
                    // that do the actual writing; tie sits beside it because both act on the note you just placed.
                    HStack(spacing: 4) {
                        durationKeys
                        tripletKey
                        EditorContextOps.buttons(viewModel: viewModel, isFlexible: usesFlexibleKeys)
                        deleteKey
                    }
                    HStack(spacing: 4) {
                        pitchKeys
                        pitchStepKeys
                    }
                }
            }
        }
        // Every key goes inert while the transport is running — see `EditorViewModel.isPlaybackActive`. Disabling the
        // whole card (rather than each key) also greys it, which is the cue that the pad is asleep, not broken.
        .disabled(viewModel.isPlaybackActive)
        // Three rows of keys is already a big bite out of a phone screen, so the card's own chrome is kept thin: the
        // keys stay 44 pt tall (the touch target is the part that must not shrink) and the padding around them gives
        // way instead.
        .padding(.horizontal, 8)
        .padding(.vertical, Self.cardVerticalPadding)
        .regularGlassCompat(in: RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal, 12)
    }

    private static let rowSpacing: CGFloat = 3
    private static let cardVerticalPadding: CGFloat = 5

    // MARK: Key groups

    /// The seven duration keys. Tapping arms the duration for the next input AND, with a selection present, applies
    /// it immediately (`EditorViewModel.setDuration(_:)`). The armed key shows a persistent accent capsule.
    private var durationKeys: some View {
        ForEach(PadDurationGlyph.ordered, id: \.glyph) { duration, glyph in
            Button {
                viewModel.setDuration(duration)
            } label: {
                PadKeyGlyph.duration(glyph)
            }
            .buttonStyle(PadKeyStyle(isArmed: viewModel.armedDuration == duration, isFlexible: usesFlexibleKeys))
            .accessibilityLabel(Self.durationLabel(duration))
        }
    }

    /// Duration accessibility labels, kept as `LocalizedStringKey` literals so `xcstringstool` keeps extracting them.
    private static func durationLabel(_ duration: NoteDuration) -> Text {
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

    /// The seven pitch-letter keys (C…B). Letter names are universal and intentionally not localized.
    private var pitchKeys: some View {
        ForEach(Self.pitchLetters, id: \.self) { letter in
            Button {
                viewModel.inputPitch(letter: Character(letter.lowercased()))
            } label: {
                PadKeyGlyph.pitchLetter(letter)
            }
            .buttonStyle(PadKeyStyle(isFlexible: usesFlexibleKeys))
            .accessibilityLabel(Text(verbatim: String(letter)))
        }
    }

    /// ♯/♭ semitone keys. A tap shifts by a semitone; a long-press shifts by an octave instead (spec §5.3) — the two
    /// are mutually exclusive, never both. See `PitchStepButton` for how that exclusivity is enforced. The glyphs are
    /// ♯ / ♭ rather than chevrons because a semitone step is what a musician reads as sharpening or flattening;
    /// chevrons read as "scroll" on a pad full of note values.
    private var pitchStepKeys: some View {
        HStack(spacing: 4) {
            PitchStepButton(
                glyph: "♯", label: "editor.pad.pitchUp", semitones: 1, octaves: 1,
                viewModel: viewModel, isFlexible: usesFlexibleKeys,
            )
            PitchStepButton(
                glyph: "♭", label: "editor.pad.pitchDown", semitones: -1, octaves: -1,
                viewModel: viewModel, isFlexible: usesFlexibleKeys,
            )
        }
    }

    /// Triplet key. A tap turns the selection into a triplet, or takes it back out of one — the armed capsule shows
    /// which. It sits with the durations because a tuplet is a duration decision: it re-times the slots the duration
    /// keys just set. Only triplets: they're the overwhelming majority of what these parts use, and a menu of sizes
    /// cost a key and an extra tap to reach the one everybody wanted.
    private var tripletKey: some View {
        Button {
            if viewModel.isSelectionInTuplet {
                viewModel.removeTuplet()
            } else {
                viewModel.createTuplet(actualNotes: 3)
            }
        } label: {
            EditorContextOps.textGlyph("3")
        }
        .buttonStyle(PadKeyStyle(isArmed: viewModel.isSelectionInTuplet, isFlexible: usesFlexibleKeys))
        .accessibilityLabel(Text("editor.ops.tuplet", bundle: .module))
    }

    private var deleteKey: some View {
        Button {
            viewModel.deleteSelection()
        } label: {
            PadKeyGlyph.symbol("delete.backward")
        }
        .buttonStyle(PadKeyStyle(isFlexible: usesFlexibleKeys))
        .tint(.primary)
        .accessibilityLabel(Text("editor.pad.delete", bundle: .module))
    }
}

/// A single ▴/▾ pitch-step key. Tap and long-press must be mutually exclusive — a real long-press (hold past the
/// threshold, then lift) has to apply ONLY `shiftOctave`, never also `shiftPitch` on release.
///
/// `.simultaneousGesture` deliberately does not suppress the `Button`'s own tap recognizer, so without a guard a
/// long-press would fire both: `shiftOctave` when `LongPressGesture` reaches its threshold, and `shiftPitch` when the
/// finger lifts and the `Button` sees that as a completed tap — moving the note 13 semitones across two undo steps.
/// `didOctaveShift` closes that gap: `LongPressGesture.onEnded` fires at the hold threshold, strictly before the
/// tap fires on release, so by the time the `Button` action runs it can check the flag and swallow the spurious tap.
private struct PitchStepButton: View {
    let glyph: String
    let label: LocalizedStringKey
    let semitones: Int
    let octaves: Int
    let viewModel: EditorViewModel
    let isFlexible: Bool

    @State private var didOctaveShift = false

    var body: some View {
        Button {
            if didOctaveShift {
                didOctaveShift = false
            } else {
                viewModel.shiftPitch(bySemitones: semitones)
            }
        } label: {
            EditorContextOps.textGlyph(glyph)
        }
        .buttonStyle(PadKeyStyle(isFlexible: isFlexible))
        .simultaneousGesture(LongPressGesture().onEnded { _ in
            didOctaveShift = true
            viewModel.shiftOctave(by: octaves)
        })
        .accessibilityLabel(Text(label, bundle: .module))
    }
}

#if DEBUG
/// Preview-only VM factory + fakes for this file's `#Preview`s. Production code never instantiates these; they exist
/// solely so the previews below can build an `EditorViewModel` without depending on Infrastructure adapters or the
/// test target's `@testable` fakes (not visible to this source target). Mirrors
/// `Tests/EditorTests/Support/Fakes.swift` and Reader's `PreviewSupport.swift`; `internal` and `#if DEBUG`-guarded so
/// it compiles into debug builds only and is stripped from release.
enum PreviewEditorFactory {
    @MainActor
    static func makeViewModel(armedDuration: NoteDuration? = nil) -> EditorViewModel {
        let viewModel = EditorViewModel(
            scoreItem: sampleItem,
            scoresDirectory: URL(filePath: "/tmp"),
            gateway: NoopScoreFileGateway(),
            repository: NoopScoreLibraryRepository(),
            playback: nil,
        )
        if let armedDuration {
            viewModel.setDuration(armedDuration)
        }
        return viewModel
    }

    private static var sampleItem: ScoreItem {
        ScoreItem(
            title: "Preview",
            composer: nil,
            instrumentationSummary: nil,
            localFileName: "preview.mscx",
            contentHash: "preview",
            sizeBytes: 0,
            lengthBeats: 0,
            defaultTempoBpm: 120,
            primaryKey: nil,
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastOpenedAt: nil,
            tagIDs: [],
            isFavorite: false,
        )
    }
}

private final class NoopScoreFileGateway: ScoreFileGateway, @unchecked Sendable {
    func detectFormat(fileName _: String) -> ScoreFormat? {
        .mscx
    }

    func loadFileMetadata(fileURL _: URL) throws -> ScoreFileSummary {
        throw DomainError.unsupportedFormat("preview")
    }

    func loadScore(fileURL _: URL) throws -> (score: Score, summary: ScoreFileSummary) {
        throw DomainError.unsupportedFormat("preview")
    }

    func saveScore(_: Score, fileURL _: URL, format _: ScoreFormat) throws {}
}

@MainActor
@Observable
private final class NoopScoreLibraryRepository: ScoreLibraryRepository {
    var scoreItems: [ScoreItem] = []
    var deletedScoreItems: [ScoreItem] = []
    var tags: [Tag] = []
    var playlists: [Playlist] = []

    func refresh() throws {}
    func saveScoreItem(_: ScoreItem) throws {}
    func deleteScoreItem(id _: ScoreItemID) throws {}
    func softDeleteScoreItem(id _: ScoreItemID) throws {}
    func restoreScoreItem(id _: ScoreItemID) throws {}
    func permanentlyDeleteScoreItem(id _: ScoreItemID) throws {}
    func pruneScoreItemsDeleted(before _: Date) throws {}
    func saveTag(_: Tag) throws {}
    func deleteTag(id _: TagID) throws {}
    func savePlaylist(_: Playlist) throws {}
    func deletePlaylist(id _: PlaylistID) throws {}
    func scoreItems(matchingContentHash _: String) throws -> [ScoreItem] {
        []
    }

    func loadReaderPreferences(for _: ScoreItemID) throws -> ReaderPreferences? {
        nil
    }

    func saveReaderPreferences(_: ReaderPreferences) throws {}
}

#Preview("pad · compact") {
    VStack {
        Spacer()
        EditorPadView(viewModel: PreviewEditorFactory.makeViewModel(armedDuration: .eighth))
    }
    .frame(width: 390)
    .background(Color.gray.opacity(0.15))
    .environment(\.horizontalSizeClass, .compact)
}

#Preview("pad · regular") {
    VStack {
        Spacer()
        EditorPadView(viewModel: PreviewEditorFactory.makeViewModel(armedDuration: .eighth))
    }
    .frame(width: 900)
    .background(Color.gray.opacity(0.15))
    .environment(\.horizontalSizeClass, .regular)
}
#endif
