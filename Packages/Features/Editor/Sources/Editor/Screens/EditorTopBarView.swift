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
    /// it (review Important 2). `doneButton`'s `minWidth: 60` is what makes `.folded` unconditionally narrower than
    /// `.expanded` — see the comment there.
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
        revertConfirmation(on: controlTierRow)
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
                row(collapse: .folded)
            }
        }
    }

    /// One candidate row for `ViewThatFits`, used only where there is no cutout tier.
    private func row(collapse: Collapse) -> some View {
        HStack(spacing: 12) {
            voiceMenu
            padToggleButton
            Spacer(minLength: 0)
            undoButton
            redoButton
            switch collapse {
            case .expanded:
                // `EditorRevertButton` already self-guards on `canRevertToOriginal`, but an EMPTY child still
                // claims its `HStack` spacing on both sides — an invisible button would still push `doneButton`
                // an extra 12pt away from `redoButton`. Guarding here too keeps it out of the layout entirely
                // when there's nothing to revert to (the common state early in a session).
                if viewModel.canRevertToOriginal {
                    EditorRevertButton(viewModel: viewModel)
                }
                doneButton
            case .folded:
                overflowMenu
            }
        }
    }

    /// Narrow-width stand-in for revert (if available) and 完了 once they've folded together.
    private var overflowMenu: some View {
        Menu {
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

    // MARK: - 完了 / revert

    /// `EditorDoneButton` pinned to a `minWidth` comfortably above the 44pt icon it folds into — deliberately, NOT
    /// left to the localized "Done"/"完了"/"완료" text's own intrinsic width. That text can render narrower than
    /// 44pt in some locales, which would make `.folded` WIDER than `.expanded` in exactly the (common) case where
    /// revert isn't available yet and 完了 is the only thing folding — the same dead-rung failure mode as review
    /// Important 2, just hiding in a different corner. Pinning the wide form's minimum width above the folded
    /// form's fixed width makes the saving positive by construction, not by hoping a given locale's text is long
    /// enough.
    private var doneButton: some View {
        EditorDoneButton(onDone: onDone)
            .frame(minWidth: 60, minHeight: 44)
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

    /// The confirmation. Destructive and not undoable, so it names what goes and what stays, and adds the caveat for
    /// an item whose recorded original predates the feature.
    ///
    /// Attached to `controlTierRow` — this view's OWN root, not the specific `EditorRevertButton` that raised it.
    /// The brief asked for the opposite (anchor to the button, for a precise iPad popover source), but that button
    /// is mounted inside a `ViewThatFits` candidate (or, on a cutout-tier device, in the Reader's `ReaderCutoutTier`
    /// entirely outside this view), and both can be torn down and remounted by a refold or a device rotation. A
    /// dialog anchored to a view that disappears mid-interaction is a worse defect than an arrow pointing at the row
    /// instead of the icon — this repo has already shipped that exact presentation-teardown bug once. Do not "fix"
    /// this back to a per-button anchor without re-solving that problem first (review Important 3 ruling).
    private func revertConfirmation(on content: some View) -> some View {
        content
            .confirmationDialog(
                Text(
                    viewModel.revertsToConversionOutput
                        ? "editor.revert.confirm.title.pdf" : "editor.revert.confirm.title",
                    bundle: .module,
                ),
                isPresented: $viewModel.isConfirmingRevert,
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
