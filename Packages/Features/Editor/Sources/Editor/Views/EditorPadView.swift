import Domain
import EditorCore
import Foundation
import Observation
import SwiftUI
import UtilityUI

/// Bottom editing pad, composed into the Reader seam above the bottom transport's reserved clearance
/// (`ReaderTransportControl.expandedContentHeight`, 110 pt) so the two never overlap. Liquid Glass card, floating
/// over the score.
///
/// iPhone (compact width), two 44 pt rows:
///  1. what the next note will BE — the durations (whole … sixteenth), the tuplet key, the tie key, the dot key;
///  2. what to write — the pitch letters C–B, with the rest key at the right end.
///
/// The split is by job, not by convenience: everything on row 1 arms or re-times, everything on row 2 acts. ♯ / ♭
/// are on neither — they live in `EditorCalloutView`, floating beside the note they alter.
///
/// Stepping the selection (← / →) lives OUTSIDE the pad, in its own pill beside the transport, so it stays put when
/// the pad is re-docked and doesn't cost the pad a row.
///
/// A wide iPad puts the same keys on ONE row. That is a question about width, not about the device — an iPad mini is
/// the same regular size class as a 13" iPad with 400 pt less to spend, and the one-row layout ran clean off both
/// ends of the card there. So the row is offered first and the two-row stacking is the fallback, chosen by whether
/// the row actually fits (`ViewThatFits`) rather than by what the size class calls the device.
public struct EditorPadView: View {
    @Bindable private var viewModel: EditorViewModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    public init(viewModel: EditorViewModel) {
        self.viewModel = viewModel
    }

    private static let pitchLetters: [Character] = ["C", "D", "E", "F", "G", "A", "B"]
    /// Height of the dividers separating key groups on the one-row layout.
    private static let dividerHeight: CGFloat = 28

    public var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                // Compact width never has room for the one row, so it isn't even offered there — measuring it would
                // only cost a layout pass to reach the same answer.
                ViewThatFits(in: .horizontal) {
                    singleRow
                    stackedRows
                }
            } else {
                stackedRows
            }
        }
        // Every key goes inert while the transport is running — see `EditorViewModel.isPlaybackActive` — and equally
        // when there is neither a caret nor a selection, since then no key has anything to act on. Disabling the
        // whole card (rather than each key) also greys it, which is the cue that the pad is asleep, not broken.
        .disabled(viewModel.isPlaybackActive || !viewModel.hasEditTarget)
        // Three rows of keys is already a big bite out of a phone screen, so the card's own chrome is kept thin: the
        // keys stay 44 pt tall (the touch target is the part that must not shrink) and the padding around them gives
        // way instead.
        .padding(.horizontal, 8)
        .padding(.vertical, Self.cardVerticalPadding)
        .regularGlassCompat(in: RoundedRectangle(cornerRadius: 20))
        // The whole card is the touch surface, not just the keys: `glassEffect` is an effect, not content, so the
        // gaps between keys (spacings, dividers, the card's own padding) hit-tested as nothing and a swipe that
        // landed on one fell straight through the chrome and scrolled the score — intermittently, because it
        // depended on where the finger came down. Same lesson as the pull tab's `contentShape`.
        .contentShape(RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal, Self.horizontalMargin)
    }

    /// The breathing room between the glass card and the screen edges. The chrome's tuck geometry subtracts it so
    /// the CARD — the visible thing — is what parks flush against an edge and aligns with the pull tab; the margin
    /// only matters while the pad rests at its centered layout position.
    static let horizontalMargin: CGFloat = 12

    private static let rowSpacing: CGFloat = 3
    private static let cardVerticalPadding: CGFloat = 5

    // MARK: Layouts

    /// Everything on one row, keys at their natural 40 pt minimum and the groups told apart by dividers. Fixed
    /// widths are the point: they are what makes this layout measurable, so `ViewThatFits` can tell whether it fits
    /// before showing it.
    private var singleRow: some View {
        HStack(spacing: 6) {
            durationKeys(isFlexible: false)
            tripletKey(isFlexible: false)
            dotKey(isFlexible: false)
            Divider().frame(height: Self.dividerHeight)
            if viewModel.isDrumStaffActive {
                // One row means one row: the kit's keys run inline where the letters would, and `ViewThatFits`
                // decides whether fifteen of them plus the durations actually fit before showing it.
                drumRows(isFlexible: false)
            } else {
                pitchKeys(isFlexible: false)
                Divider().frame(height: Self.dividerHeight)
                EditorContextOps.buttons(viewModel: viewModel)
                restKey(isFlexible: false)
            }
        }
    }

    /// Two 44 pt rows split by job, not by convenience: row 1 arms or re-times, row 2 writes.
    ///
    /// The keys share the row's width instead of claiming a fixed minimum, so this layout cannot overflow by
    /// construction — on the narrowest supported phone (375 pt) each key still lands around 29 pt wide, and the
    /// 44 pt row height keeps the touch targets tall enough to hit.
    private var stackedRows: some View {
        VStack(spacing: Self.rowSpacing) {
            HStack(spacing: 4) {
                durationKeys(isFlexible: true)
                tripletKey(isFlexible: true)
                EditorContextOps.buttons(viewModel: viewModel, isFlexible: true)
                dotKey(isFlexible: true)
            }
            if viewModel.isDrumStaffActive {
                drumRows(isFlexible: true)
            } else {
                HStack(spacing: 4) {
                    pitchKeys(isFlexible: true)
                    restKey(isFlexible: true)
                }
            }
        }
    }

    /// The kit in place of the letters. Row 1 above is untouched — a drum staff arms lengths, tuplets, ties and dots
    /// exactly as a pitched one does — and the rest key keeps its pitched meaning, now closing the kit's first row
    /// with the `⋯` menu closing its last.
    ///
    /// There is no manual drum-mode switch: the score already says which kind of staff the caret is on, and a toggle
    /// would be a second source of truth the user has to keep in sync.
    private func drumRows(isFlexible: Bool) -> some View {
        EditorDrumPadRows(
            layout: viewModel.drumPadLayout,
            litPitches: viewModel.litDrumPitches,
            isFlexible: isFlexible,
            press: { viewModel.pressDrumKey($0) },
            restKey: AnyView(restKey(isFlexible: isFlexible)),
            moreKey: AnyView(
                EditorDrumMoreMenu(
                    layout: viewModel.drumPadLayout,
                    litPitches: viewModel.litDrumPitches,
                    isFlexible: isFlexible,
                    press: { viewModel.pressDrumKey($0) },
                    editLayout: { viewModel.isDrumLayoutSheetPresented = true },
                ),
            ),
        )
    }

    // MARK: Key groups

    /// The duration keys. Tapping arms that length for the next input — it does NOT re-time anything already
    /// written. The armed key shows a persistent accent capsule; picking a note or rest with nothing armed yet lights
    /// the key matching what was picked (`EditorViewModel.armFromSelectionIfNeeded`).
    private func durationKeys(isFlexible: Bool) -> some View {
        ForEach(PadDurationGlyph.ordered, id: \.glyph) { duration, glyph in
            PadDurationKey(
                duration: duration,
                glyph: glyph,
                isSelected: viewModel.armedDuration == duration,
                isFlexible: isFlexible,
            ) {
                viewModel.setDuration(duration)
            }
        }
    }

    /// The seven pitch-letter keys (C…B). Letter names are universal and intentionally not localized.
    private func pitchKeys(isFlexible: Bool) -> some View {
        ForEach(Self.pitchLetters, id: \.self) { letter in
            Button {
                viewModel.inputPitch(letter: Character(letter.lowercased()))
            } label: {
                PadKeyGlyph.pitchLetter(letter)
            }
            .buttonStyle(PadKeyStyle(isFlexible: isFlexible))
            .accessibilityLabel(Text(verbatim: String(letter)))
        }
    }

    /// Tuplet key. A tap turns the caret's slot into a tuplet of the armed size, or takes it back out of one — the
    /// capsule shows which. It sits with the durations because a tuplet is a duration decision: it re-times the slots
    /// the duration keys just set.
    ///
    /// The sizes live behind a long press (`Menu`'s `primaryAction:` is exactly this: tap runs the action, hold opens
    /// the menu) so the pad doesn't spend keys on ratios nobody reaches for — and the key then WEARS the last size
    /// picked, because a piece that wants quintuplets wants them more than once and shouldn't need the menu each
    /// time.
    private func tripletKey(isFlexible: Bool) -> some View {
        Menu {
            ForEach(Self.tupletSizes, id: \.self) { size in
                Button {
                    viewModel.createTuplet(actualNotes: size)
                } label: {
                    Text("editor.ops.tupletCount \(size)", bundle: .module)
                }
            }
        } label: {
            EditorContextOps.textGlyph("\(viewModel.armedTuplet)")
                .padKeyChrome(isArmed: viewModel.isCaretInTuplet, isFlexible: isFlexible)
        } primaryAction: {
            if viewModel.isCaretInTuplet {
                viewModel.removeTuplet()
            } else {
                viewModel.createTuplet(actualNotes: viewModel.armedTuplet)
            }
        }
        .tint(.primary)
        .accessibilityLabel(Text("editor.ops.tuplet", bundle: .module))
    }

    /// Tuplet sizes the long-press menu offers. 7 and up are vanishingly rare in the parts this edits and would only
    /// make the menu longer to read.
    private static let tupletSizes = Array(2 ... 6)

    private func dotKey(isFlexible: Bool) -> some View {
        PadDotKey(
            dots: viewModel.armedDots,
            isFlexible: isFlexible,
            setDots: { viewModel.setArmedDots($0) },
            toggle: { viewModel.toggleArmedDot() },
        )
    }

    /// The rest key — a write key, and the pitch letters' silent twin: it writes into the slot the CARET marks and
    /// then moves the caret on, so ♩ ♩𝄽 ♩ types straight through. It draws the ARMED length's rest, so the key
    /// shows the silence you are about to get.
    ///
    /// Inert only when the caret is on nothing timed. It is not a ⌫ — deleting a note is what this key does when
    /// the caret is ON that note, which a tap or ← / → puts it there.
    private func restKey(isFlexible: Bool) -> some View {
        Button {
            viewModel.writeRest()
        } label: {
            PadKeyGlyph.rest(viewModel.armedDuration)
        }
        .buttonStyle(PadKeyStyle(isFlexible: isFlexible))
        .disabled(!viewModel.canWriteRest)
        .accessibilityLabel(Text("editor.pad.rest", bundle: .module))
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
            originalStore: NoopScoreOriginalStore(),
            historyStore: NoopScoreEditHistoryStore(),
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

    func allReaderPreferences() throws -> [ReaderPreferences] {
        []
    }
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
