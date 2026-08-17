import Domain
import SheetMusicCore
import SwiftUI

/// The Reader's two inspector destinations — playback settings and display settings — resolved from the view model in
/// one place, so whoever presents them cannot drift apart about what a given button opens.
///
/// Regular width anchors a `.popover` directly to the inspector button in `ReaderTopBarControls`, which is safe there
/// because that button lives OUTSIDE the `ViewThatFits` fold — it never folds into the overflow menu, so it never
/// carries a presentation modifier into content that has no representation once folded. Compact width can't use the
/// same popover — it degrades to a full-screen sheet anyway — so `ReaderRootScreen` presents the identical content as
/// a `.sheet` instead (`inspectorSheet` below), keeping the two in exact sync via this one type.
@MainActor
struct ReaderInspectorDestinations {
    let viewModel: ReaderViewModel

    /// Invoked when re-reading the PDF would discard the user's work — the screen presents the confirmation. A re-read
    /// with nothing to lose runs straight from the control and never reaches here.
    var onConfirmReReadPDF: () -> Void = {}

    /// `true` while fixed-layout pages are what's on screen: a PDF folino never read into notation, or a converted
    /// item showing its original. That state gets the PDF inspectors — a fixed-layout page can't be re-engraved, so
    /// the engraving settings have nothing to act on.
    var showsPDFChrome: Bool {
        if viewModel.displaySource == .originalPDF { return true }
        if case .loadedPDF = viewModel.loadState { return true }
        return false
    }

    /// The score the playback inspector acts on, or `nil` when there is nothing to play yet — an unconverted PDF whose
    /// background OMR parse hasn't landed. A loaded score is always playable, including while its original pages show.
    var playbackScore: Score? {
        guard viewModel.canPlayNow else { return nil }
        return viewModel.playbackScore
    }

    /// Whether the playback inspector offers the render-derived staff-visibility eye. Only the score reader can: the
    /// list is derived from what was engraved, and a fixed-layout page engraves nothing.
    var showsStaffVisibility: Bool {
        !showsPDFChrome
    }

    /// The PDF controls the display inspector carries, or `nil` for an item that never came from a PDF — which hides
    /// the whole section. With the badge gone once the notation is showing, the inspector is the one place that still
    /// says "this came from a PDF, and here is what you can do about it".
    var pdfOriginControls: PDFOriginControls? {
        guard viewModel.scoreItem.pdfOriginState != .notPDF else { return nil }
        return PDFOriginControls(
            showsOriginalPDF: viewModel.displaySource == .originalPDF,
            setShowsOriginalPDF: viewModel.canShowOriginalPDF
                ? { showsOriginal in viewModel.setDisplaySource(showsOriginal ? .originalPDF : .score) }
                : nil,
            reParse: viewModel.canReReadPDF
                ? {
                    if viewModel.reReadNeedsConfirmation {
                        onConfirmReReadPDF()
                    } else {
                        Task { await viewModel.reReadPDF() }
                    }
                }
                : nil,
        )
    }

    @ViewBuilder
    var playbackInspector: some View {
        if let playbackScore {
            PlaybackInspectorScreen(
                mixerModel: viewModel.mixerModel,
                layoutModel: viewModel.layoutModel,
                tempoModel: viewModel.tempoModel,
                masterVolumeModel: viewModel.masterVolumeModel,
                a4ReferenceModel: viewModel.a4ReferenceModel,
                repeatModel: viewModel.repeatModel,
                transposeModel: viewModel.transposeModel,
                score: playbackScore,
                playbackSession: viewModel.playbackSession,
                isInPlaylist: viewModel.isInPlaylist,
                showsStaffVisibility: showsStaffVisibility,
            )
            .frame(idealWidth: 380, idealHeight: 600)
            .presentationDetents([.large])
            .presentationCompactAdaptation(.sheet)
        }
    }

    @ViewBuilder
    var displayInspector: some View {
        if showsPDFChrome {
            PDFLayoutInspectorScreen(pdfOrigin: pdfOriginControls)
                .frame(idealWidth: 320, idealHeight: 320)
                .presentationDetents([.medium])
                .presentationCompactAdaptation(.sheet)
        } else if let score = viewModel.loadState.score {
            VisualInspectorScreen(
                layoutModel: viewModel.layoutModel,
                transposeModel: viewModel.transposeModel,
                score: score,
                pdfOrigin: pdfOriginControls,
            )
            .frame(idealWidth: 380, idealHeight: 600)
            .presentationDetents([.medium, .large])
            .presentationCompactAdaptation(.sheet)
        }
    }
}

extension View {
    /// Anchors `content` to this view as a popover, but only where an anchor is worth having. At compact width the
    /// Reader presents the same content as a sheet from the screen instead, which keeps this button free of any
    /// presentation modifier — see `ReaderInspectorDestinations` for why that matters.
    @ViewBuilder
    func inspectorPopover(
        isPresented: Binding<Bool>,
        anchored: Bool,
        @ViewBuilder content: @escaping () -> some View,
    ) -> some View {
        if anchored {
            popover(isPresented: isPresented, content: content)
        } else {
            self
        }
    }

    /// The compact-width counterpart of `inspectorPopover`: the screen presents what the strip's button can't.
    @ViewBuilder
    func inspectorSheet(
        isPresented: Binding<Bool>,
        enabled: Bool,
        @ViewBuilder content: @escaping () -> some View,
    ) -> some View {
        if enabled {
            sheet(isPresented: isPresented, content: content)
        } else {
            self
        }
    }
}
