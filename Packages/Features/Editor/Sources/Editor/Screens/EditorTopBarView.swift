import Domain
import SwiftUI
import UtilityUI

/// The editing session's own content for the Reader's top strip (`ReaderRootScreen.editingTopBar`, Task 5). Ported
/// from `EditorChromeView+Toolbar.swift`'s navigation-bar items (voice, pad toggle, undo, redo, 完了) and
/// `EditorChromeView+Revert.swift`'s revert control, now drawn as plain views instead of `ToolbarContent` — the
/// Reader's own strip replaced the navigation bar these used to fill.
///
/// Two tiers, matching the Reader's own (`ReaderTopBarLayout`, which this package cannot import — Feature → Feature
/// is forbidden — so the App precomputes `hasCutoutTier` / `topSafeAreaInset` from the Reader's own measurement and
/// hands them down through `ReaderEditingChromeContext`):
///
/// * **Cutout tier**, where there is one: 完了 leading, revert trailing — the two controls that end the session, in
///   the two spots Photos uses for the same purpose. `cutoutTierOverlay` draws it by escaping this view's own
///   control-tier box (fixed at `ReaderTopBarLayout.controlTierHeight` by `ReaderTopBar`) into the reserved band
///   above it, exactly as `ReaderCutoutTier` escapes the Reader's own strip — this package just cannot reuse that
///   type, so the same `offset` / `ignoresSafeArea` shape is re-declared locally.
/// * **Control tier**: the voice picker and pad toggle lead, undo and redo trail. Where there is no cutout tier,
///   完了 and revert join this row — five controls wide — and the whole thing folds with `ViewThatFits`, the same
///   ladder the Reader's own row uses. Fold order: revert first, then 完了, into an overflow menu — they're the two
///   that have a home in the cutout tier on other devices, so folding them here costs nothing they don't already
///   give up somewhere.
public struct EditorTopBarView: View {
    @Bindable var viewModel: EditorViewModel
    let hasMusicalAnnotations: Bool
    /// Whether this device's top safe-area inset is wide enough to host a control — see
    /// `ReaderTopBarLayout.hasCutoutTier(topSafeAreaInset:)`, computed by the App and handed down as a plain value.
    let hasCutoutTier: Bool
    /// The reserved band's height, used only to size and center the cutout tier — see `cutoutTierOverlay`.
    let topSafeAreaInset: CGFloat
    let onDone: () -> Void
    /// Reports the pad-toggle button's window frame — the coach-mark anchor `ReaderEditingHost.noteInputAnchorFrame`
    /// points at — or `nil` once the button leaves the screen.
    let onNoteInputAnchorFrameChange: (CGRect?) -> Void

    /// Drives the revert confirmation dialog. Moved here (Task 5) from `EditorChromeView`: the button that raises it
    /// now lives in this view, in a different part of the tree, and the dialog has to anchor to it to read correctly
    /// as a popover on iPad.
    @State private var isConfirmingRevert = false
    /// Mirrors `EditorChromeView.isPadVisible` through the same `UserDefaults` key. The pad toggle lives here now;
    /// the pad itself still lives in `EditorChromeView`. `@AppStorage` keeps two declarations of the same key in
    /// sync without either view needing to see the other's state.
    @AppStorage("editorPadVisible") private var isPadVisible = false

    /// How much the control tier gives up as width tightens, when 完了 and revert are IN it (no cutout tier). Fold
    /// order: revert first, then 完了.
    enum Collapse: Int, CaseIterable, Comparable {
        case expanded
        case revert
        case done

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    public init(
        viewModel: EditorViewModel,
        hasMusicalAnnotations: Bool,
        hasCutoutTier: Bool,
        topSafeAreaInset: CGFloat,
        onDone: @escaping () -> Void,
        onNoteInputAnchorFrameChange: @escaping (CGRect?) -> Void,
    ) {
        self.viewModel = viewModel
        self.hasMusicalAnnotations = hasMusicalAnnotations
        self.hasCutoutTier = hasCutoutTier
        self.topSafeAreaInset = topSafeAreaInset
        self.onDone = onDone
        self.onNoteInputAnchorFrameChange = onNoteInputAnchorFrameChange
    }

    public var body: some View {
        revertConfirmation(on: content)
    }

    private var content: some View {
        controlTierRow
            .overlay(alignment: .top) {
                if hasCutoutTier {
                    cutoutTierOverlay
                }
            }
    }

    // MARK: - Cutout tier

    /// 完了 leading, revert trailing — escaped from this view's own (fixed-height) box up into the reserved band
    /// above it. The base sits right below the true device inset (that's what `ReaderTopBar`'s own doc comment means
    /// by "the system's own top inset is already below the strip's content"), so offsetting up by exactly that
    /// amount lands this at the true top of the screen — the same band `ReaderCutoutTier` draws into for the
    /// Reader's own (non-editing) strip.
    private var cutoutTierOverlay: some View {
        HStack {
            doneButton
            Spacer(minLength: 0)
            if viewModel.canRevertToOriginal {
                revertButton
            }
        }
        .frame(height: topSafeAreaInset, alignment: .center)
        .frame(maxWidth: .infinity, alignment: .top)
        .offset(y: -topSafeAreaInset)
        .ignoresSafeArea(edges: .top)
    }

    // MARK: - Control tier

    @ViewBuilder
    private var controlTierRow: some View {
        if hasCutoutTier {
            // 完了 and revert live in the cutout tier; four controls never risk running out of room, so no fold.
            HStack(spacing: 12) {
                voiceMenu
                padToggleButton
                Spacer(minLength: 0)
                undoButton
                redoButton
            }
        } else {
            // `Spacer(minLength: 0)` inside `row(collapse:)` is what lets `ViewThatFits` fold at all — a greedy
            // spacer would make every candidate report that it fits, and the fold would silently never trigger.
            ViewThatFits(in: .horizontal) {
                row(collapse: .expanded)
                row(collapse: .revert)
                row(collapse: .done)
            }
        }
    }

    /// One candidate row for `ViewThatFits`, used only where there is no cutout tier — 完了 and revert are folded
    /// into an overflow menu (in that order) as `collapse` increases.
    private func row(collapse: Collapse) -> some View {
        HStack(spacing: 12) {
            voiceMenu
            padToggleButton
            Spacer(minLength: 0)
            if collapse < .revert, viewModel.canRevertToOriginal {
                revertButton
            }
            undoButton
            redoButton
            if collapse < .done {
                doneButton
            }
            if collapse >= .revert, viewModel.canRevertToOriginal || collapse >= .done {
                overflowMenu(collapse: collapse)
            }
        }
    }

    /// Narrow-width stand-in for the revert / 完了 controls once they've folded. Never shown for both at once and
    /// empty at the same time — see the guard at the call site.
    private func overflowMenu(collapse: Collapse) -> some View {
        Menu {
            if viewModel.canRevertToOriginal {
                revertMenuRow
            }
            if collapse >= .done {
                doneMenuRow
            }
        } label: {
            topBarIcon("ellipsis")
        }
        .tint(.primary)
        .accessibilityLabel(L10n.Common.more)
    }

    // MARK: - Voice / pad toggle

    private var voiceMenu: some View {
        Menu {
            EditorVoicePicker(viewModel: viewModel)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "person.2")
                Text(verbatim: "\(viewModel.activeVoice + 1)")
                    .fontWeight(.semibold)
            }
            .frame(minWidth: 44, minHeight: 44)
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
            Image("custom.music.note.badge.plus", bundle: .module)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(isPadVisible ? Color(uiColor: .systemBackground) : Color.primary)
                .offset(x: -1.5)
                .frame(width: 30, height: 30)
                .background {
                    if isPadVisible {
                        Circle().fill(Color.primary)
                    }
                }
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

    private func topBarButton(
        system: String, label: LocalizedStringKey, enabled: Bool, action: @escaping () -> Void,
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

    // MARK: - 完了

    private var doneButton: some View {
        Button(action: onDone) {
            Text("editor.chrome.done", bundle: .module)
                .fontWeight(.semibold)
                .frame(height: 44)
        }
        .tint(.primary)
    }

    private var doneMenuRow: some View {
        Button(action: onDone) {
            Label {
                Text("editor.chrome.done", bundle: .module)
            } icon: {
                Image(systemName: "checkmark")
            }
        }
    }

    // MARK: - Revert

    /// A top-level control now, not folded into a permanent `⋯` menu — see the type's own doc comment. Destructive:
    /// raises the confirmation rather than acting immediately.
    private var revertButton: some View {
        Button(role: .destructive) {
            isConfirmingRevert = true
        } label: {
            topBarIcon("arrow.counterclockwise")
        }
        .tint(.primary)
        .accessibilityLabel(Text(
            viewModel.revertsToConversionOutput ? "editor.revert.action.pdf" : "editor.revert.action",
            bundle: .module,
        ))
    }

    private var revertMenuRow: some View {
        Button(role: .destructive) {
            isConfirmingRevert = true
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

    /// The confirmation. Destructive and not undoable, so it names what goes and what stays, and adds the caveat for
    /// an item whose recorded original predates the feature.
    private func revertConfirmation(on content: some View) -> some View {
        content
            .confirmationDialog(
                Text(
                    viewModel.revertsToConversionOutput
                        ? "editor.revert.confirm.title.pdf" : "editor.revert.confirm.title",
                    bundle: .module,
                ),
                isPresented: $isConfirmingRevert,
                titleVisibility: .visible,
            ) {
                Button(role: .destructive) {
                    Task { await viewModel.revertToOriginal() }
                } label: {
                    Text("editor.revert.confirm.action", bundle: .module)
                }
                Button(role: .cancel) {} label: {
                    Text("editor.revert.confirm.cancel", bundle: .module)
                }
            } message: {
                Text(revertMessage)
            }
            // A revert that fails silently is worse than the dialog it replaced: the confirmation closes either way,
            // so without this the user has no way to tell "reverted" apart from "the store threw and nothing
            // happened". `revertError` is cleared on dismiss so a later successful revert can't re-show a stale
            // alert.
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
                if !isPresented { viewModel.revertError = nil }
            },
        )
    }

    private var revertMessage: String {
        let warnings = viewModel.revertWarnings(hasMusicalAnnotations: hasMusicalAnnotations)
        var lines = [String(localized: "editor.revert.confirm.body", bundle: .module)]
        if warnings.contains(.musicalAnnotationsMayShift) {
            lines.append(String(localized: "editor.revert.confirm.inkMayShift", bundle: .module))
        }
        if warnings.contains(.originalMayNotBeImportTime) {
            lines.append(String(localized: "editor.revert.confirm.mayNotBeImport", bundle: .module))
        }
        return lines.joined(separator: "\n\n")
    }
}
