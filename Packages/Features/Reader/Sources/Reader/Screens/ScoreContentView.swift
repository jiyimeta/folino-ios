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
/// the toolbar overlay and its inspector sheet stay stable. Every input below changes at most on a user action (layout
/// switch, staff-size drag, transpose), never per tick — so this view re-renders per tick solely from its own cursor
/// reads.
struct ScoreContentView: View {
    let viewModel: ReaderViewModel
    let layoutMode: ReaderLayoutMode
    let pdfLayoutMode: ReaderLayoutMode
    let collapseMultiMeasureRests: Bool
    let showInvisibleElements: Bool
    let autoFollowEnabled: Bool
    let pageTurnButtonsVisible: Bool
    let bottomControlContentHeight: CGFloat

    var body: some View {
        switch viewModel.loadState {
        case .loading:
            ProgressView().controlSize(.large)
        case .loaded:
            // `visibleScore` is the clef-applied / transposed / hidden-filtered score, cached on the view model and
            // recomputed only when its inputs change — so this body no longer rebuilds the score on every re-eval.
            if let visible = viewModel.visibleScore {
                switch layoutMode {
                case .vertical:
                    VerticalScoreContainer(
                        score: visible,
                        staffSize: viewModel.layoutModel.staffSize,
                        honorLayoutBreaks: viewModel.layoutModel.honorLayoutBreaks,
                        collapseMultiMeasureRests: collapseMultiMeasureRests,
                        showInvisibleElements: showInvisibleElements,
                        playbackCursor: viewModel.playbackSession.displayCursor,
                        scrollAnchorCursor: viewModel.playbackSession.scrollAnchorCursor,
                        autoFollowEnabled: autoFollowEnabled,
                        transposeSemitones: viewModel.transposeModel.semitones,
                        bottomControlClearance: bottomControlContentHeight,
                        viewModel: viewModel,
                    )
                case .horizontal:
                    HorizontalScoreContainer(
                        score: visible,
                        staffSize: viewModel.layoutModel.staffSize,
                        honorLayoutBreaks: viewModel.layoutModel.honorLayoutBreaks,
                        collapseMultiMeasureRests: collapseMultiMeasureRests,
                        showInvisibleElements: showInvisibleElements,
                        playbackCursor: viewModel.playbackSession.displayCursor,
                        scrollAnchorCursor: viewModel.playbackSession.scrollAnchorCursor,
                        autoFollowEnabled: autoFollowEnabled,
                        transposeSemitones: viewModel.transposeModel.semitones,
                        viewModel: viewModel,
                    )
                case .page:
                    PagedScoreContainer(
                        score: visible,
                        staffSize: viewModel.layoutModel.staffSize,
                        honorLayoutBreaks: viewModel.layoutModel.honorLayoutBreaks,
                        collapseMultiMeasureRests: collapseMultiMeasureRests,
                        showInvisibleElements: showInvisibleElements,
                        playbackCursor: viewModel.playbackSession.displayCursor,
                        pageAnchorCursor: viewModel.playbackSession.pageAnchorCursor,
                        autoFollowEnabled: autoFollowEnabled,
                        showsPageTurnButtons: pageTurnButtonsVisible,
                        transposeSemitones: viewModel.transposeModel.semitones,
                        viewModel: viewModel,
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
