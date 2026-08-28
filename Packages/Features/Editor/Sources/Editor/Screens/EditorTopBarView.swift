import Domain
import SwiftUI
import UtilityUI

/// The editing session's control tier (`ReaderRootScreen.editingTopBar`) — voice picker, pad toggle, undo, redo,
/// and, where there is no cutout tier, 完了 and revert too. Ported from `EditorChromeView+Toolbar.swift`'s
/// navigation-bar items and `EditorChromeView+Revert.swift`'s revert control, now drawn as plain views instead of
/// `ToolbarContent` — the Reader's own strip replaced the navigation bar these used to fill.
///
/// **The cutout tier is NOT drawn here.** Where one exists, 完了 and revert are mounted by the Reader's own
/// `ReaderCutoutTier` instead (`ReaderRootScreen.editingCutoutTier`, using the shared `EditorDoneButton` /
/// `EditorRevertButton` views) — review Important 4: an earlier draft re-declared `ReaderCutoutTier`'s
/// `offset`/`ignoresSafeArea` shape locally (this package cannot import `Reader` to reuse the type itself), which
/// left two independently-positioned mechanisms both claiming the same band, exactly what the design spec warns
/// against. Reusing the Reader's real layout code makes that structurally impossible instead of merely unlikely.
///
/// **Control tier**: the voice picker and pad toggle lead, undo and redo trail. Where there is no cutout tier, 完了
/// and revert join this row — five controls wide — and the whole thing folds with `ViewThatFits`, the same ladder
/// shape the Reader's own row uses (`Collapse`, `Spacer(minLength: 0)`, fixed icon frames).
public struct EditorTopBarView: View {
    @Bindable var viewModel: EditorViewModel
    let hasMusicalAnnotations: Bool
    /// Whether this device's top safe-area inset is wide enough to host a control — see
    /// `ReaderTopBarLayout.hasCutoutTier(topSafeAreaInset:)`, computed by the App and handed down as a plain value
    /// (this package cannot import `Reader` to read `ReaderTopBarLayout` itself).
    let hasCutoutTier: Bool
    let onDone: () -> Void
    /// Reports the pad-toggle button's window frame — the coach-mark anchor `ReaderEditingHost.noteInputAnchorFrame`
    /// points at — or `nil` once the button leaves the screen.
    let onNoteInputAnchorFrameChange: (CGRect?) -> Void

    /// Mirrors `EditorChromeView.isPadVisible` through the same `UserDefaults` key. The pad toggle lives here now;
    /// the pad itself still lives in `EditorChromeView`. `@AppStorage` keeps two declarations of the same key in
    /// sync without either view needing to see the other's state.
    @AppStorage("editorPadVisible") private var isPadVisible = false

    /// How much the control tier gives up as width tightens, when 完了 and revert are IN it (no cutout tier).
    ///
    /// Only two rungs, not three: a `.revert`-only middle rung (revert alone folded into `⋯`, 完了 still a
    /// standalone text button) measures IDENTICAL to `.expanded` whenever revert is showing — swapping one 44×44
    /// icon (`revertButton`) for another (the `⋯` menu) saves nothing, so `ViewThatFits` could never actually pick
    /// it. `.expanded` carries the instruments button and `measureMenu` (44×44 each) ALONGSIDE the session-end
    /// control (`endGroup`), while `.folded` merges all three into the one `⋯` (`overflowMenu`) — so `.folded` is
    /// unconditionally narrower than `.expanded`, by two 44pt controls plus 24pt of spacing, in every
    /// `sessionEndMode`, not only `.revert`.
    enum Collapse {
        case expanded
        case folded
    }

    public init(
        viewModel: EditorViewModel,
        hasMusicalAnnotations: Bool,
        hasCutoutTier: Bool,
        onDone: @escaping () -> Void,
        onNoteInputAnchorFrameChange: @escaping (CGRect?) -> Void,
    ) {
        self.viewModel = viewModel
        self.hasMusicalAnnotations = hasMusicalAnnotations
        self.hasCutoutTier = hasCutoutTier
        self.onDone = onDone
        self.onNoteInputAnchorFrameChange = onNoteInputAnchorFrameChange
    }

    public var body: some View {
        // The shadow matches `ReaderTopBarControls`' so the reading and editing strips read as the same physical
        // surface — see review Important 2.
        measureMenuSheets(on: instrumentsSheet(on: revertFailureAlert(on: controlTierRow)))
            .shadow(color: .gray.opacity(0.3), radius: 10, y: 5)
    }

    // MARK: - Control tier

    @ViewBuilder
    private var controlTierRow: some View {
        if hasCutoutTier {
            // ✕ and the session-end control live in the cutout tier; the six controls left here (undo, redo,
            // voice, pad, the instruments sheet, and the measure-actions menu) still sit under this row's width on
            // the narrowest device that HAS a cutout tier — so no fold is needed here.
            //
            // That device is a 375pt notched phone (12/13 mini, 11 Pro, XS), NOT the 393pt modern class:
            // `ReaderTopBarLayout.hasCutoutTier` keys off the top safe-area inset, which those reach. The budget is
            // 6×44 + 5×12 = 324pt of controls against 375 − 32 (the strip's own horizontal padding) = 343pt — about
            // 19pt of slack before whatever `glassEffect` adds around each pill, which is thin enough that the
            // 375-wide preview below is the check, not the arithmetic. A device narrower than that has no cutout
            // tier and takes the folding branch below.
            HStack(spacing: 12) {
                undoRedoGroup
                Spacer(minLength: 0)
                voiceButton
                padButton
                instrumentsButton
                measureMenu
                    .interactiveGlassCompat()
            }
        } else {
            // `Spacer(minLength: 0)` inside `row(collapse:)` is what lets `ViewThatFits` fold at all — a greedy
            // spacer would make every candidate report that it fits, and the fold would silently never trigger.
            //
            // Every `sessionEndMode` goes through the fold now, not only `.revert`: `.expanded` carries the
            // measure-actions menu ADDITIONALLY to the session-end control, while `.folded` merges both into the
            // one `⋯` (`overflowMenu`) — so `.expanded` is unconditionally wider than `.folded` in every mode (see
            // `Collapse`'s own doc comment for the exact margin). Before this menu existed, the checkmark states
            // measured identically and the fold there was dead code; it is reachable now.
            ViewThatFits(in: .horizontal) {
                row(collapse: .expanded)
                row(collapse: .folded)
            }
        }
    }

    /// One candidate row for `ViewThatFits`, used only where there is no cutout tier — so this row carries ✕ and the
    /// session-end control itself, which on a cutout device live in the band instead.
    private func row(collapse: Collapse) -> some View {
        HStack(spacing: 12) {
            EditorDiscardButton(viewModel: viewModel, onExit: onDone)
                .interactiveGlassCompat()
            undoRedoGroup
            Spacer(minLength: 0)
            voiceButton
            padButton
            switch collapse {
            case .expanded:
                HStack(spacing: 12) {
                    instrumentsButton
                    measureMenu
                        .interactiveGlassCompat()
                    endGroup
                }
            case .folded:
                overflowMenu
                    .interactiveGlassCompat()
            }
        }
    }

    /// Undo + redo, sharing one glass pill, leading — the pairing is the point: they are one control's two
    /// directions, and Photos puts the same pair in the same place.
    private var undoRedoGroup: some View {
        HStack(spacing: 0) {
            undoButton
            redoButton
        }
        .interactiveGlassCompat()
    }

    /// The voice picker and the pad toggle trail, and each carries its own pill rather than sharing one: they are
    /// unrelated — which voice you are writing into, and whether the keyboard is up — and a shared surface said they
    /// were a pair. Bare glyphs still need something behind them to stay legible over arbitrary score content
    /// (review Important 2), so each gets glass of its own.
    private var voiceButton: some View {
        voiceMenu
            .interactiveGlassCompat()
    }

    private var padButton: some View {
        padToggleButton
            .interactiveGlassCompat()
    }

    /// The session-end control — checkmark or revert, depending on `EditorViewModel.sessionEndMode`. One control,
    /// three states; it carries its own surface and its own confirmation.
    private var endGroup: some View {
        EditorSessionEndButton(
            viewModel: viewModel,
            onExit: onDone,
            hasMusicalAnnotations: hasMusicalAnnotations,
        )
    }

    /// Narrow-width stand-in for the instruments sheet, the measure actions, revert (if available), and 完了 once
    /// they've folded together.
    private var overflowMenu: some View {
        Menu {
            instrumentsMenuRow
            measureActionRows
            if viewModel.canRevertToOriginal {
                revertMenuRow
            }
            doneMenuRow
        } label: {
            topBarIcon("ellipsis")
        }
        .tint(.primary)
        .accessibilityLabel(L10n.Common.more)
    }

    /// Stand-in for the measure actions in the layouts that don't fold `overflowMenu`'s revert/done rows in with
    /// them — the cutout-tier row (no `ViewThatFits` at all) and `row(collapse: .expanded)` (where the session-end
    /// control keeps its own dedicated space). Both need somewhere for these three rows to live that isn't already
    /// spoken for.
    private var measureMenu: some View {
        Menu {
            measureActionRows
        } label: {
            topBarIcon("ellipsis")
        }
        .tint(.primary)
        .accessibilityLabel(L10n.Common.more)
    }

    /// Add / insert-before / delete a measure, plus the bar-scoped rows from `measureMenuRows` (the two signature
    /// changes and the rehearsal mark) — shared by `overflowMenu` and `measureMenu`, which each host these rows
    /// alongside different neighbours.
    @ViewBuilder
    private var measureActionRows: some View {
        Button {
            viewModel.appendMeasure()
        } label: {
            Label {
                Text("editor.measure.append", bundle: .module)
            } icon: {
                Image(systemName: "plus.rectangle")
            }
        }
        Button {
            viewModel.insertMeasureBeforeTarget()
        } label: {
            Label {
                Text("editor.measure.insertBefore", bundle: .module)
            } icon: {
                Image(systemName: "plus.rectangle.on.rectangle")
            }
        }
        .disabled(viewModel.targetMeasureIndex == nil)
        // Ahead of the destructive row, not after it: a `Menu` puts its destructive item last everywhere else in
        // this app, and appending these two below Delete Measure would break that reading.
        measureMenuRows
        Button(role: .destructive) {
            viewModel.deleteTargetMeasure()
        } label: {
            Label {
                Text("editor.measure.delete", bundle: .module)
            } icon: {
                Image(systemName: "minus.rectangle")
            }
        }
        .disabled(viewModel.targetMeasureIndex == nil || viewModel.measureCount <= 1)
    }

    // MARK: - Voice / pad toggle

    private var voiceMenu: some View {
        Menu {
            EditorVoicePicker(viewModel: viewModel)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "person.2")
                Text(verbatim: "\(viewModel.activeVoice + 1)")
                    .fontWeight(.semibold)
            }
            // Padded rather than squeezed into a bare 44pt square: the icon and the numeral together are almost
            // exactly 44pt wide, so a minimum-width frame put the glass hard against both of them.
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
        }
        .tint(.primary)
        .accessibilityLabel(Text("editor.voice.label", bundle: .module))
    }

    /// Shows and hides the pad. Same fixed-frame glyph as the old toolbar item — see that file's history for why the
    /// disc is inverted ink rather than the accent tint, and why the glyph frame never changes size.
    private var padToggleButton: some View {
        Button {
            withAnimation(.snappy(duration: 0.28)) { isPadVisible.toggle() }
        } label: {
            // Mode-on is the FILLED variant of the same glyph, exactly like the annotation pen button
            // (`pencil.tip.crop.circle.fill`): the disc is symbol ink, which glass renders at full strength,
            // where a `Circle().fill` drawn in the label — background OR content — comes out washed into the
            // material. The knocked-out note/plus show the glass through, the system's own fill-variant look.
            Image(
                isPadVisible ? "custom.music.note.badge.plus.fill" : "custom.music.note.badge.plus",
                bundle: .module,
            )
            // The outline symbolset marks its note layer hierarchical:secondary; under the glass chrome iOS
            // renders hierarchically by default, dimming that layer even when the control is enabled. Monochrome
            // keeps the whole glyph at full foreground strength, matching the SF Symbol neighbours.
            .symbolRenderingMode(.monochrome)
                .font(.system(size: isPadVisible ? 26 : 21, weight: .medium))
                .foregroundStyle(Color.primary)
                .offset(x: isPadVisible ? 0 : -1.5)
                // The 44pt frame is the control's own, so the pill matches its neighbours instead of shrink-wrapping
                // the glyph.
                .frame(width: 44, height: 44)
        }
        .tint(.primary)
        .accessibilityLabel(Text(
            isPadVisible ? "editor.chrome.hidePad" : "editor.chrome.showPad", bundle: .module,
        ))
        // The chrome is rendered inside the Reader's own view tree now, so both sides share a window coordinate
        // space and this can simply report where it is — see `ReaderEditingHost.noteInputAnchorFrame`.
        .onWindowFrameChange { onNoteInputAnchorFrameChange($0) }
        .onDisappear { onNoteInputAnchorFrameChange(nil) }
    }

    // MARK: - Undo / redo

    private var undoButton: some View {
        topBarButton(system: "arrow.uturn.backward", label: "editor.chrome.undo", enabled: viewModel.canUndo) {
            viewModel.undo()
        }
    }

    private var redoButton: some View {
        topBarButton(system: "arrow.uturn.forward", label: "editor.chrome.redo", enabled: viewModel.canRedo) {
            viewModel.redo()
        }
    }

    /// Internal rather than private so `EditorTopBarView+Instruments.swift` builds its button out of the same
    /// pieces as undo and redo instead of restating them.
    func topBarButton(
        system: String, label: LocalizedStringKey, enabled: Bool = true, action: @escaping () -> Void,
    ) -> some View {
        Button(action: action) {
            topBarIcon(system)
        }
        .tint(.primary)
        .disabled(!enabled)
        .accessibilityLabel(Text(label, bundle: .module))
    }

    /// The 44×44 tappable glyph shared by the strip's icon buttons — every button keeps this fixed frame so what a
    /// `ViewThatFits` candidate needs is a function of how many buttons it has, not of their content.
    private func topBarIcon(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 20, weight: .medium))
            .frame(width: 44, height: 44)
    }

    // MARK: - Session end

    private var doneMenuRow: some View {
        Button(action: onDone) {
            Label {
                Text("editor.chrome.done", bundle: .module)
            } icon: {
                Image(systemName: "checkmark")
            }
        }
    }

    private var revertMenuRow: some View {
        Button(role: .destructive) {
            viewModel.isConfirmingRevert = true
        } label: {
            Label {
                // A PDF-origin sidecar is the conversion's output, not the file the user imported — the imported
                // PDF is a separate original sitting in the same sheet, so this must not call the sidecar "the
                // original" a second time (design spec, "Two originals must never be called the same thing").
                Text(
                    viewModel.revertsToConversionOutput ? "editor.revert.action.pdf" : "editor.revert.action",
                    bundle: .module,
                )
            } icon: {
                Image(systemName: "arrow.counterclockwise")
            }
        }
    }

    /// A revert that fails silently is worse than no confirmation at all: the popover closes either way, so
    /// without this the user has no way to tell "reverted" apart from "the store threw and nothing happened".
    /// `revertError` is cleared on dismiss so a later successful revert can't re-show a stale alert.
    ///
    /// This one stays on the row rather than moving to the button with the confirmations: by the time it has
    /// something to say the revert has already ended the session, so the control that raised it is gone.
    private func revertFailureAlert(on content: some View) -> some View {
        content
            .alert(
                Text("editor.revert.failed", bundle: .module),
                isPresented: isRevertErrorPresented,
            ) {
                Button {
                    viewModel.revertError = nil
                } label: {
                    Text("editor.revert.failed.dismiss", bundle: .module)
                }
            } message: {
                Text(viewModel.revertError ?? "")
            }
    }

    private var isRevertErrorPresented: Binding<Bool> {
        Binding(
            get: { viewModel.revertError != nil },
            set: { isPresented in
                if !isPresented {
                    viewModel.revertError = nil
                }
            },
        )
    }
}
