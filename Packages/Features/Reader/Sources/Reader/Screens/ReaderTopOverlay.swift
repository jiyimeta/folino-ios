import Domain
import ScoreUI
import SheetMusicCore
import SwiftUI
import UtilityUI

/// Top overlay hosting Back / Inspector buttons. Rendered inside `ReaderRootScreen`'s `ZStack` so the score
/// stays visible behind the buttons — maximising the rendered staff area, which is core to the app's value proposition.
///
/// We sidestep the standard `.toolbar { … }` route because on iOS 26.3.x physical devices
/// `.toolbarBackgroundVisibility(.hidden, for: .navigationBar)` fails to suppress the navigation bar's chrome
/// (confirmed working only from iOS 26.4 simulator). Once 26.4+ adoption is broad, this overlay can likely be reverted
/// to a plain `ToolbarContent`.
struct ReaderTopOverlay: View {
    @Bindable var viewModel: ReaderViewModel
    /// The leading affordance's action, or `nil` to hide it entirely. In a `NavigationStack` (compact) it pops back to
    /// the library; in the iPad split-view detail it reveals the sidebar column. `nil` is used by the split-view detail
    /// while both columns are already visible.
    let onBack: (() -> Void)?

    /// When `true`, the leading button renders as a sidebar-reveal affordance (`sidebar.leading` icon, "show sidebar"
    /// label) rather than a back chevron. Set by the iPad split-view detail, where tapping reveals the library sidebar
    /// column instead of popping a navigation stack. Has no effect when `onBack` is `nil` (no leading button shown).
    var leadingIsSidebarToggle = false

    /// Invoked when the user taps the PDF badge — the parent (`ReaderRootScreen`) presents the PDF-playback caveat
    /// dialog. Defaults to a no-op so previews can omit it.
    var onShowPDFNotice: () -> Void = {}

    /// Invoked when the user taps the "edit notes" button. `nil` hides the button entirely — the default, so previews
    /// and PDF readers (which never wire an `editingHost`) are unaffected.
    var onStartEditing: (() -> Void)?

    /// Vertical space the overlay occupies inside the safe area (button 40 + top padding 4 + a little breathing room).
    /// Used by `ReaderRootScreen` to extend the score's safe area so the first staff is never hidden under the floating
    /// buttons. `nonisolated` so non–main-actor contexts (preview helpers, `onGeometryChange` transform closures) can
    /// read this layout constant without hopping actors.
    nonisolated static let height: CGFloat = 52

    var body: some View {
        HStack(spacing: 12) {
            if let onBack {
                overlayButton(
                    systemImage: leadingIsSidebarToggle ? "sidebar.leading" : "chevron.backward",
                    label: leadingIsSidebarToggle
                        ? Text("reader.toolbar.showSidebar", bundle: .module)
                        : Text("reader.toolbar.back", bundle: .module),
                    action: onBack,
                )
                .interactiveGlassCompat()
            }
            if !viewModel.capabilities.canPlay {
                // `canPlay == false` ⇔ PDF in this reader: a tappable brand badge that opens the PDF-playback caveat
                // dialog — reachable any time, in place of an always-on note.
                Button { onShowPDFNotice() } label: { PDFBadge() }
                    .buttonStyle(.plain)
            }
            Spacer()

            if case let .loaded(score) = viewModel.loadState {
                loadedActions(score: score)
            } else if case .loadedPDF = viewModel.loadState {
                pdfActions
            }
        }
        .shadow(color: .gray.opacity(0.3), radius: 10, y: 5)
        .padding(.horizontal)
        .padding(.top, 4)
    }

    /// Right-side buttons that depend on a loaded score: the "this score" pill (info + share) left of the annotation
    /// toggle, left of the paired inspector pill. Play/pause moved to the bottom transport control
    /// (`ReaderTransportControl`) so the primary transport controls sit within thumb reach. Extracted from `body` to
    /// keep the outer HStack closure under SwiftLint's body-length limit.
    private func loadedActions(score: Score) -> some View {
        HStack(spacing: 12) {
            scoreActionButtons()
            if let onStartEditing {
                overlayButton(
                    systemImage: "square.and.pencil",
                    label: Text("reader.toolbar.edit.start", bundle: .module),
                    action: onStartEditing,
                )
                .interactiveGlassCompat()
            }
            annotationToggleButton()
                .interactiveGlassCompat()
            inspectorButtons(score: score)
                .interactiveGlassCompat()
        }
        .sheet(isPresented: $viewModel.isScoreInfoPresented) {
            EditScoreInfoSheet(model: viewModel, item: viewModel.scoreItem)
                .onAppear { viewModel.analytics.logScreen(.scoreInfo) }
        }
        .sheet(item: $viewModel.shareTarget) { target in
            ActivityViewControllerRepresentable(items: target.urls)
        }
    }

    /// The "this score" pill: score-info (opens the edit-info sheet) + share (lazy format menu). Sits left of the
    /// inspector pill so document actions are grouped apart from playback/display settings.
    private func scoreActionButtons() -> some View {
        HStack(spacing: 0) {
            overlayButton(
                systemImage: "info.circle",
                label: Text("reader.toolbar.showInfo", bundle: .module),
            ) {
                viewModel.presentScoreInfo()
            }

            Menu {
                ShareFormatMenuItems(
                    loadFormats: { [viewModel] in await viewModel.availableShareFormats() },
                    onShare: { format in
                        Task { await viewModel.requestShare(format: format) }
                    },
                )
            } label: {
                overlayIcon("square.and.arrow.up")
            }
            .tint(.primary)
            .accessibilityLabel(Text("reader.toolbar.share", bundle: .module))
        }
        .interactiveGlassCompat()
    }

    /// Single-button glass pill that toggles annotation mode. When active, the canvas accepts Pencil/finger input;
    /// when inactive, all touches reach navigation and tap-to-seek. Disabled during playback: entering draw mode hides
    /// the transport, which would strand the user with no visible way to pause — so the toggle is gated until stopped.
    private func annotationToggleButton() -> some View {
        let isPlaying = viewModel.playbackSession.isPlaying
        return Button {
            viewModel.toggleAnnotation()
        } label: {
            annotationGlyph
        }
        .tint(.primary)
        .accessibilityLabel(Text(
            viewModel.isAnnotating
                ? "reader.toolbar.annotate.stop"
                : "reader.toolbar.annotate.start",
            bundle: .module,
        ))
        .disabled(isPlaying)
        // Dim the glyph while disabled so the unavailable state reads at a glance, matched to the transport's fade.
        .opacity(isPlaying ? 0.35 : 1)
        .animation(.easeOut(duration: 0.2), value: isPlaying)
    }

    /// The annotation button's glyph. Same symbol in both states — no icon swap. Pen mode fills the whole button with a
    /// black disc (inset 2pt from the glass pill's edge) and draws the `pencil.tip.crop.circle` in white on top, so
    /// "active" reads as a colour inversion rather than a different shape.
    @ViewBuilder
    private var annotationGlyph: some View {
        if viewModel.isAnnotating {
            Image(systemName: "pencil.tip.crop.circle")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background {
                    Circle()
                        .fill(.black)
                        .padding(2)
                }
        } else {
            overlayIcon("pencil.tip.crop.circle")
        }
    }

    /// Paired playback / visual inspector buttons sharing a single glass-pill background. Each button owns its own
    /// popover anchored to itself so the popover arrow points at the tapped icon.
    private func inspectorButtons(score: Score) -> some View {
        HStack(spacing: 0) {
            playbackInspectorButton(score: score)

            overlayButton(
                systemImage: "text.page",
                label: Text("reader.toolbar.showDisplaySettings", bundle: .module),
            ) {
                viewModel.isVisualInspectorPresented.toggle()
            }
            .popover(isPresented: $viewModel.isVisualInspectorPresented) {
                VisualInspectorScreen(
                    layoutModel: viewModel.layoutModel,
                    transposeModel: viewModel.transposeModel,
                    score: score,
                )
                .frame(idealWidth: 380, idealHeight: 600)
                .presentationDetents([.medium, .large])
                .presentationCompactAdaptation(.sheet)
            }
        }
    }

    /// The playback-settings button and its popover. Shared by the score reader and — once a PDF's background OMR parse
    /// succeeds — the PDF reader, which passes its parsed score and drops the render-derived staff-visibility eye.
    private func playbackInspectorButton(score: Score, showsStaffVisibility: Bool = true) -> some View {
        overlayButton(
            systemImage: "slider.vertical.3",
            label: Text("reader.toolbar.showPlaybackSettings", bundle: .module),
        ) {
            viewModel.isPlaybackInspectorPresented.toggle()
        }
        .popover(isPresented: $viewModel.isPlaybackInspectorPresented) {
            PlaybackInspectorScreen(
                mixerModel: viewModel.mixerModel,
                layoutModel: viewModel.layoutModel,
                tempoModel: viewModel.tempoModel,
                masterVolumeModel: viewModel.masterVolumeModel,
                a4ReferenceModel: viewModel.a4ReferenceModel,
                repeatModel: viewModel.repeatModel,
                transposeModel: viewModel.transposeModel,
                score: score,
                playbackSession: viewModel.playbackSession,
                isInPlaylist: viewModel.isInPlaylist,
                showsStaffVisibility: showsStaffVisibility,
            )
            .frame(idealWidth: 380, idealHeight: 600)
            .presentationDetents([.large])
            .presentationCompactAdaptation(.sheet)
        }
    }

    /// Right-side buttons for a PDF: the annotation toggle, then an inspector pill pairing the playback inspector with
    /// the PDF layout inspector. Playback settings all act on the engine, which plays a parsed PDF exactly as it plays
    /// a native score, so the whole inspector applies — it just needs the parse to have landed (before that there is no
    /// score to address, and the transport is withheld too).
    private var pdfActions: some View {
        HStack(spacing: 12) {
            annotationToggleButton()
                .interactiveGlassCompat()
            HStack(spacing: 0) {
                if viewModel.isPDFPlaybackReady, let score = viewModel.playbackScore {
                    playbackInspectorButton(score: score, showsStaffVisibility: false)
                }
                pdfLayoutButton
            }
            .interactiveGlassCompat()
        }
    }

    /// The PDF reader's display inspector: a page/vertical layout toggle plus the note about which display adjustments
    /// a fixed-layout PDF can't offer. Stands in for the score reader's visual inspector, which derives its controls
    /// from a rendered `Score`.
    private var pdfLayoutButton: some View {
        overlayButton(
            systemImage: "text.page",
            label: Text("reader.toolbar.showDisplaySettings", bundle: .module),
        ) {
            viewModel.isVisualInspectorPresented.toggle()
        }
        .popover(isPresented: $viewModel.isVisualInspectorPresented) {
            PDFLayoutInspectorScreen()
                .frame(idealWidth: 320, idealHeight: 200)
                .presentationDetents([.medium])
                .presentationCompactAdaptation(.sheet)
        }
    }

    private func overlayButton(
        systemImage: String,
        label: Text,
        action: @escaping () -> Void,
    ) -> some View {
        Button(action: action) {
            overlayIcon(systemImage)
        }
        .tint(.primary)
        .accessibilityLabel(label)
    }

    /// The 44×44 tappable glyph shared by the overlay's buttons and menus.
    private func overlayIcon(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 20, weight: .medium))
            .frame(width: 44, height: 44)
    }
}

/// A small "PDF" pill shown when the open item is a fixed-layout PDF. The text is a brand literal and is intentionally
/// not localized (iOS/Android parity).
struct PDFBadge: View {
    var body: some View {
        Text(verbatim: "PDF")
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.secondary.opacity(0.18), in: Capsule())
            .foregroundStyle(.secondary)
            .accessibilityLabel(Text(verbatim: "PDF"))
    }
}

#if DEBUG
#Preview {
    let vm = ReaderViewModel(
        scoreItem: PreviewFakeRepository.sampleItem,
        repository: PreviewFakeRepository(),
        gateway: PreviewFakeGateway(),
        scoresDirectory: URL(filePath: "/tmp"),
    )
    ReaderTopOverlay(viewModel: vm, onBack: {})
        .task {
            await vm.load()
        }
}
#endif
