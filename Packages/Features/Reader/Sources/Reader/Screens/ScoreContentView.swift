import Domain
import SwiftUI

/// The live score / PDF container selection, extracted from `ReaderRootScreen.body` so the per-tick playback-cursor
/// reads (`displayCursor` / `scrollAnchorCursor` / `pageAnchorCursor`, which drive auto-follow) stay scoped to THIS
/// view's body.
///
/// Read at the root, those cursors re-rendered `ReaderRootScreen.body` on every cursor tick during playback, which
/// rebuilt `ReaderTopOverlay` (fresh `onBack` / `onShowPDFNotice` closures each pass) and re-created its presented
/// playback-inspector popover. That regeneration snapped the per-part program `Menu` back to the top whenever the user
/// tried to scroll it mid-playback. Confining the cursor reads here lets only the score container re-render per tick;
/// the toolbar overlay and its inspector sheet stay stable.
///
/// **Editing renders through this same view, not a parallel one.** Whether the reader is editing changes only the
/// container's INPUTS — which score, and whether the display transforms apply. Branching to a separate editing view
/// instead gave each container a fresh identity on entering and leaving edit mode, which threw away the `@State`
/// `document` it had already laid out: the score blanked to the empty-state background for as long as the async
/// relayout took, reading as a white flash on every entry and exit. Feeding one container different inputs keeps the
/// previously laid-out document on screen until the new one is ready.
struct ScoreContentView: View {
    let viewModel: ReaderViewModel
    let layoutMode: ReaderLayoutMode
    let pdfLayoutMode: ReaderLayoutMode
    let collapseMultiMeasureRests: Bool
    let showInvisibleElements: Bool
    let autoFollowEnabled: Bool
    let pageTurnButtonsVisible: Bool
    let bottomControlContentHeight: CGFloat
    /// Non-nil only while note editing. Already clef-applied by the caller; raw in every other respect (no transpose,
    /// no hidden staves, no collapsed multi-measure rests) so the element indices the Editor tracks stay valid.
    let editingScore: Score?
    let editingHost: ReaderEditingHost?

    /// The score the containers render: the editing score while editing, the display-transformed one otherwise.
    private var renderedScore: Score? {
        editingScore ?? viewModel.visibleScore
    }

    /// Display transforms are suppressed while editing — they'd renumber the very elements being edited.
    private var isEditing: Bool {
        editingScore != nil
    }

    private var effectiveCollapseMultiMeasureRests: Bool {
        isEditing ? false : collapseMultiMeasureRests
    }

    private var effectiveTransposeSemitones: Int {
        isEditing ? 0 : viewModel.transposeModel.semitones
    }

    var body: some View {
        switch viewModel.loadState {
        case .loading:
            ProgressView().controlSize(.large)
        case .loaded:
            // `visibleScore` is the clef-applied / transposed / hidden-filtered score, cached on the view model and
            // recomputed only when its inputs change — so this body no longer rebuilds the score on every re-eval.
            if let score = renderedScore {
                switch layoutMode {
                case .vertical:
                    VerticalScoreContainer(
                        score: score,
                        staffSize: viewModel.layoutModel.staffSize,
                        honorLayoutBreaks: viewModel.layoutModel.honorLayoutBreaks,
                        collapseMultiMeasureRests: effectiveCollapseMultiMeasureRests,
                        showInvisibleElements: showInvisibleElements,
                        playbackCursor: viewModel.playbackSession.displayCursor,
                        scrollAnchorCursor: viewModel.playbackSession.scrollAnchorCursor,
                        autoFollowEnabled: autoFollowEnabled,
                        transposeSemitones: effectiveTransposeSemitones,
                        bottomControlClearance: bottomControlContentHeight,
                        viewModel: viewModel,
                        editingHost: editingHost,
                    )
                case .horizontal:
                    HorizontalScoreContainer(
                        score: score,
                        staffSize: viewModel.layoutModel.staffSize,
                        honorLayoutBreaks: viewModel.layoutModel.honorLayoutBreaks,
                        collapseMultiMeasureRests: effectiveCollapseMultiMeasureRests,
                        showInvisibleElements: showInvisibleElements,
                        playbackCursor: viewModel.playbackSession.displayCursor,
                        scrollAnchorCursor: viewModel.playbackSession.scrollAnchorCursor,
                        autoFollowEnabled: autoFollowEnabled,
                        transposeSemitones: effectiveTransposeSemitones,
                        viewModel: viewModel,
                        editingHost: editingHost,
                    )
                case .page:
                    PagedScoreContainer(
                        score: score,
                        staffSize: viewModel.layoutModel.staffSize,
                        honorLayoutBreaks: viewModel.layoutModel.honorLayoutBreaks,
                        collapseMultiMeasureRests: effectiveCollapseMultiMeasureRests,
                        showInvisibleElements: showInvisibleElements,
                        playbackCursor: viewModel.playbackSession.displayCursor,
                        pageAnchorCursor: viewModel.playbackSession.pageAnchorCursor,
                        autoFollowEnabled: autoFollowEnabled,
                        showsPageTurnButtons: pageTurnButtonsVisible,
                        transposeSemitones: effectiveTransposeSemitones,
                        viewModel: viewModel,
                        editingHost: editingHost,
                    )
                }
            } else {
                ProgressView().controlSize(.large)
            }
        case let .loadedPDF(document):
            switch pdfLayoutMode {
            case .vertical:
                VerticalPDFContainer(document: document, viewModel: viewModel)
            case .page, .horizontal:
                PagedPDFContainer(
                    document: document,
                    showsPageTurnButtons: pageTurnButtonsVisible,
                    viewModel: viewModel,
                )
            }
        case let .failed(error):
            ContentUnavailableView {
                Label {
                    Text("reader.error.cannotOpen.title", bundle: .module)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
            } description: {
                Text(describeReaderError(error))
            } actions: {
                Button { Task { await viewModel.load() } } label: {
                    Text("reader.error.retry", bundle: .module)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}
