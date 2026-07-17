import Domain
import Foundation
import Observation
import SwiftUI

/// Bottom editing pad. iPhone (compact width): two 44 pt rows — durations row + pitch/octave/delete row. iPad
/// (regular width): one 44 pt row with all keys. Liquid Glass card, floating over the score.
///
/// This is the first Editor CHROME view: Task 14 adds the pitch/duration callout, Task 15 composes this pad (plus the
/// callout) into the Reader seam above the bottom transport's reserved clearance
/// (`ReaderTransportControl.expandedContentHeight`, 114 pt) so the two never overlap.
public struct EditorPadView: View {
    @Bindable private var viewModel: EditorViewModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    public init(viewModel: EditorViewModel) {
        self.viewModel = viewModel
    }

    private static let durations: [(NoteDuration, String, LocalizedStringKey)] = [
        (.whole, "𝅝", "editor.duration.whole"), (.half, "𝅗𝅥", "editor.duration.half"),
        (.quarter, "♩", "editor.duration.quarter"), (.eighth, "♪", "editor.duration.eighth"),
        (.sixteenth, "𝅘𝅥𝅯", "editor.duration.sixteenth"), (.thirtySecond, "𝅘𝅥𝅰", "editor.duration.thirtySecond"),
        (.sixtyFourth, "𝅘𝅥𝅱", "editor.duration.sixtyFourth"),
    ]
    private static let pitchLetters: [Character] = ["C", "D", "E", "F", "G", "A", "B"]
    /// Height of the dividers separating key groups on the iPad one-row layout.
    private static let dividerHeight: CGFloat = 28

    public var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                HStack(spacing: 6) {
                    durationKeys
                    Divider().frame(height: Self.dividerHeight)
                    pitchKeys
                    Divider().frame(height: Self.dividerHeight)
                    pitchStepKeys
                    deleteKey
                }
            } else {
                VStack(spacing: 6) {
                    HStack(spacing: 4) { durationKeys }
                    HStack(spacing: 4) { pitchKeys; pitchStepKeys; deleteKey }
                }
            }
        }
        .padding(10)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22))
        .padding(.horizontal)
    }

    // MARK: Key groups

    /// The seven duration keys. Tapping arms the duration for the next input AND, with a selection present, applies
    /// it immediately (`EditorViewModel.setDuration(_:)`). The armed key shows a persistent accent capsule.
    private var durationKeys: some View {
        ForEach(Self.durations, id: \.1) { duration, glyph, key in
            Button {
                viewModel.setDuration(duration)
            } label: {
                PadKeyGlyph.duration(glyph)
            }
            .buttonStyle(PadKeyStyle(isArmed: viewModel.armedDuration == duration))
            .accessibilityLabel(Text(key, bundle: .module))
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
            .buttonStyle(PadKeyStyle())
            .accessibilityLabel(Text(verbatim: String(letter)))
        }
    }

    /// ▴/▾ semitone keys. A tap shifts by a semitone; a long-press shifts by an octave instead (spec §5.3).
    private var pitchStepKeys: some View {
        HStack(spacing: 4) {
            pitchStepKey(systemName: "chevron.up", label: "editor.pad.pitchUp", semitones: 1, octaves: 1)
            pitchStepKey(systemName: "chevron.down", label: "editor.pad.pitchDown", semitones: -1, octaves: -1)
        }
    }

    private func pitchStepKey(
        systemName: String, label: LocalizedStringKey, semitones: Int, octaves: Int,
    ) -> some View {
        Button {
            viewModel.shiftPitch(bySemitones: semitones)
        } label: {
            PadKeyGlyph.symbol(systemName)
        }
        .buttonStyle(PadKeyStyle())
        .simultaneousGesture(LongPressGesture().onEnded { _ in
            viewModel.shiftOctave(by: octaves)
        })
        .accessibilityLabel(Text(label, bundle: .module))
    }

    private var deleteKey: some View {
        Button {
            viewModel.deleteSelection()
        } label: {
            PadKeyGlyph.symbol("delete.backward")
        }
        .buttonStyle(PadKeyStyle())
        .tint(.primary)
        .accessibilityLabel(Text("editor.pad.delete", bundle: .module))
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
