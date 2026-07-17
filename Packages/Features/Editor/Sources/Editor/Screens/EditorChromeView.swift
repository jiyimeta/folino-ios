import SheetMusicCore
import SwiftUI

/// Full-screen editing chrome. The App injects this into the Reader seam (Task 15) so it floats over the live score.
/// Layout:
///  - top-right: an undo / redo / 完了 glass cluster mirroring `ReaderTopOverlay`'s 44 pt buttons + 12 pt spacing;
///  - bottom: the Task 13 `EditorPadView`;
///  - compact width: `EditorCalloutView` floating near `selectionAnchor` (a global-space rect handed in by the seam);
///  - regular width: `EditorPaletteView` docked to the trailing edge, vertically centered.
///
/// `selectionAnchor` is the selection's rect in global coordinates; the chrome converts it to local space and clamps
/// the callout on-screen. The callout is hidden entirely when there is no selection or no anchor.
public struct EditorChromeView: View {
    @Bindable private var viewModel: EditorViewModel
    private let selectionAnchor: CGRect?
    private let onDone: () -> Void
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.undoManager) private var undoManager

    /// Measured size of the rendered `EditorCalloutView` capsule (Task 16 carry-over fix), captured via
    /// `.onGeometryChange` in `callout(anchor:proxy:)`. Seeded to the OLD hardcoded estimate (2×180 / 2×30) so the
    /// very first frame — before any measurement has landed — clamps exactly as before; every frame after that uses
    /// the callout's real size, so the clamp no longer collapses on narrow phones.
    @State private var calloutSize = CGSize(width: 360, height: 60)

    /// One-time "saved as .mscz" notice (Task 16, spec §11-2) — shown at most once per install.
    @AppStorage("editorSiblingMSCZNoticeShown") private var siblingMSCZNoticeShown = false
    @State private var showsSiblingNotice = false

    public init(viewModel: EditorViewModel, selectionAnchor: CGRect?, onDone: @escaping () -> Void) {
        self.viewModel = viewModel
        self.selectionAnchor = selectionAnchor
        self.onDone = onDone
    }

    /// Vertical clearance reserved at the bottom for the pad + the Reader transport's expanded height, used both to
    /// inset the pad and to keep the floating callout from overlapping it.
    private static let bottomClearance: CGFloat = 130

    public var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topTrailing) {
                if horizontalSizeClass == .regular {
                    EditorPaletteView(viewModel: viewModel)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                        .padding(.trailing)
                } else if viewModel.selectedItem != nil, let anchor = selectionAnchor {
                    callout(anchor: anchor, proxy: proxy)
                }

                topCluster
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

                EditorPadView(viewModel: viewModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 8)
            }
        }
        // Task 16: bridges ScoreEditor's undo/redo stacks to the system UndoManager so three-finger swipe gestures
        // work. [Task 17 verify] confirm the three-finger swipe reaches this view's UndoManager through the glass
        // overlay hierarchy on device — if it doesn't, the on-screen undo/redo buttons remain the primary path.
        .onChange(of: viewModel.generation) { _, _ in
            viewModel.registerSystemUndo(with: undoManager)
        }
        .onDisappear {
            undoManager?.removeAllActions(withTarget: viewModel)
        }
        .onChange(of: viewModel.didSaveAsSiblingMSCZ) { _, saved in
            guard saved, !siblingMSCZNoticeShown else { return }
            siblingMSCZNoticeShown = true
            showsSiblingNotice = true
        }
        .overlay(alignment: .top) {
            if showsSiblingNotice {
                siblingMSCZNoticeBanner
                    .task {
                        try? await Task.sleep(for: .seconds(4))
                        showsSiblingNotice = false
                    }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showsSiblingNotice)
    }

    // MARK: One-time sibling-mscz notice

    /// Top-center glass banner (spec §11-2): informs the user their edits are now saved as a sibling `.mscz` copy,
    /// the first time a non-MuseScore source gets rewritten that way. Mirrors `DrainBannerView`'s capsule + auto-
    /// dismiss pattern (`App/DrainBannerView.swift`).
    private var siblingMSCZNoticeBanner: some View {
        Text("editor.notice.savedAsMscz", bundle: .module)
            .font(.footnote)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: Capsule())
            .padding(.top, 8)
            .padding(.horizontal, 24)
            .shadow(color: .gray.opacity(0.3), radius: 10, y: 5)
            .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: Top cluster

    private var topCluster: some View {
        HStack(spacing: 0) {
            clusterIconButton(system: "arrow.uturn.backward", label: "editor.chrome.undo", enabled: viewModel.canUndo) {
                viewModel.undo()
            }
            clusterIconButton(system: "arrow.uturn.forward", label: "editor.chrome.redo", enabled: viewModel.canRedo) {
                viewModel.redo()
            }
            Button {
                onDone()
            } label: {
                Text("editor.chrome.done", bundle: .module)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 44)
            }
            .tint(.primary)
        }
        .glassEffect(.regular.interactive())
        .shadow(color: .gray.opacity(0.3), radius: 10, y: 5)
        .padding(.horizontal)
        .padding(.top, 4)
    }

    private func clusterIconButton(
        system: String,
        label: LocalizedStringKey,
        enabled: Bool,
        action: @escaping () -> Void,
    ) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 20, weight: .medium))
                .frame(width: 44, height: 44)
        }
        .tint(.primary)
        .disabled(!enabled)
        .accessibilityLabel(Text(label, bundle: .module))
    }

    // MARK: Callout positioning

    /// Places the callout centered horizontally over the selection and just above it, clamped so it stays at least
    /// 8 pt inside the horizontal edges and above the bottom pad clearance. Task 16 carry-over fix: the clamp uses
    /// the callout's ACTUAL measured size (`calloutSize`, captured below via `.onGeometryChange`) instead of a
    /// hardcoded half-width — on phones narrower than the old ~360 pt estimate (≤376 pt), the fixed constant made
    /// `minX > maxX` collapse to a single point, so the callout stopped tracking the selection and sat dead-center.
    /// With the real width, `minX`/`maxX` stay correctly ordered down to any phone width the callout itself fits on.
    private func callout(anchor: CGRect, proxy: GeometryProxy) -> some View {
        let global = proxy.frame(in: .global)
        let localMidX = anchor.midX - global.minX
        let localMinY = anchor.minY - global.minY

        let halfWidth = calloutSize.width / 2
        let halfHeight = calloutSize.height / 2
        let inset: CGFloat = 8

        let minX = halfWidth + inset
        let maxX = max(minX, proxy.size.width - halfWidth - inset)
        let clampedX = min(max(localMidX, minX), maxX)

        let topLimit = proxy.safeAreaInsets.top + halfHeight + inset
        let bottomLimit = max(topLimit, proxy.size.height - Self.bottomClearance - halfHeight)
        let desiredY = localMinY - halfHeight - 12
        let clampedY = min(max(desiredY, topLimit), bottomLimit)

        return EditorCalloutView(viewModel: viewModel)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { newSize in
                calloutSize = newSize
            }
            .position(x: clampedX, y: clampedY)
    }
}

#if DEBUG
/// Preview-only: seed a session + selection on a `PreviewEditorFactory` VM so the callout / palette / readout render
/// populated. Reuses the Task 13 factory (`EditorPadButtons.swift`) for the Infrastructure-free fakes.
@MainActor
private func previewChromeViewModel(select item: SheetMusicCore.ScoreItemID) -> EditorViewModel {
    let viewModel = PreviewEditorFactory.makeViewModel(armedDuration: .quarter)
    viewModel.beginSession(score: previewChromeScore())
    viewModel.select(item)
    return viewModel
}

/// One 4/4 measure: element 1 is a C4 quarter chord, elements 2…4 are quarter rests.
private func previewChromeScore() -> Score {
    let voice = Voice(elements: [
        .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
        .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])),
        .rest(duration: .quarter),
        .rest(duration: .quarter),
        .rest(duration: .quarter),
    ])
    let staff = Staff(measures: [Measure(voices: [voice])])
    let part = Part(id: "1", instrument: Instrument(id: "x"), staves: [staff])
    return Score(division: 480, parts: [part])
}

private let previewStaff = StaffAddress(partIndex: 0, staffIndexInPart: 0)

#Preview("chrome · compact / rest selected") {
    let restItem = SheetMusicCore.ScoreItemID.rest(
        RestID(staff: previewStaff, measureIndex: 0, voiceIndex: 0, elementIndex: 2),
    )
    return EditorChromeView(
        viewModel: previewChromeViewModel(select: restItem),
        selectionAnchor: CGRect(x: 120, y: 300, width: 20, height: 20),
        onDone: {},
    )
    .frame(width: 390, height: 844)
    .environment(\.horizontalSizeClass, .compact)
    .background(Color.gray.opacity(0.15))
}

#Preview("chrome · regular / note selected") {
    let noteItem = SheetMusicCore.ScoreItemID.note(
        NoteID(staff: previewStaff, measureIndex: 0, voiceIndex: 0, elementIndex: 1, noteIndexInChord: 0),
    )
    return EditorChromeView(
        viewModel: previewChromeViewModel(select: noteItem),
        selectionAnchor: nil,
        onDone: {},
    )
    .frame(width: 1180, height: 820)
    .environment(\.horizontalSizeClass, .regular)
    .background(Color.gray.opacity(0.15))
}
#endif
