import Domain
import SheetMusicAudio
import SheetMusicCore
import SwiftUI
import UtilityUI

struct VisualInspectorScreen: View {
    let layoutModel: LayoutSettingsModel
    let transposeModel: TransposeModel
    let score: Score

    @AppStorage(ReaderGlobalSettingsKey.layoutMode)
    private var layoutModeRaw: String = ReaderLayoutMode.page.rawValue

    @AppStorage(ReaderGlobalSettingsKey.collapseMultiMeasureRests)
    private var collapseMultiMeasureRests = false

    @AppStorage(ReaderGlobalSettingsKey.showInvisibleElements)
    private var showInvisibleElements = false

    @AppStorage(ReaderGlobalSettingsKey.showSeekBarEnabled)
    private var showSeekBar = true

    @AppStorage(ReaderGlobalSettingsKey.autoFollowEnabled)
    private var autoFollowEnabled = true

    @AppStorage(ReaderGlobalSettingsKey.pageTurnButtonsVisible)
    private var pageTurnButtonsVisible = true

    @AppStorage("reader.inspector.visual.general.expanded") private var generalExpanded = true
    @AppStorage("reader.inspector.visual.parts.expanded") private var partsExpanded = true

    private var layoutMode: ReaderLayoutMode {
        ReaderLayoutMode(rawValue: layoutModeRaw) ?? .page
    }

    var body: some View {
        List {
            CollapsibleSection(isExpanded: $generalExpanded) {
                layoutRow
                staffSizeRow
                TransposeRow(transposeModel: transposeModel, showsIcon: false)
                breakPolicyRow
                collapseRow
                showInvisibleRow
                seekBarRow
                autoFollowRow
                if layoutMode == .page {
                    pageTurnButtonsRow
                }
            } header: {
                Text("reader.inspector.section.general", bundle: .module)
            }

            CollapsibleSection(isExpanded: $partsExpanded) {
                ForEach(score.parts.indices, id: \.self) { partIndex in
                    let part = score.parts[partIndex]
                    HStack {
                        Text(part.instrument.longName ?? part.trackName ?? "-")

                        VStack(spacing: 4) {
                            ForEach(part.staves.indices, id: \.self) { staffIndex in
                                visualStaffRow(address: StaffAddress(
                                    partIndex: partIndex,
                                    staffIndexInPart: staffIndex,
                                ))
                            }
                        }
                    }
                    .verticalRowInsetCompat(6)
                }
            } header: {
                Text("reader.inspector.section.parts", bundle: .module)
            }
        }
        .contentMargins(.top, 4, for: .scrollContent)
        .buttonStyle(.plain)
    }

    private var layoutRow: some View {
        HStack {
            Text("reader.preferences.layoutDirection", bundle: .module)
            Spacer()
            Picker(selection: $layoutModeRaw) {
                Image(systemName: "arrow.up.and.down.text.horizontal")
                    .tag(ReaderLayoutMode.vertical.rawValue)
                Image("arrow.left.and.right.text.horizontal", bundle: .module)
                    .tag(ReaderLayoutMode.horizontal.rawValue)
                Image(systemName: "book.pages")
                    .tag(ReaderLayoutMode.page.rawValue)
            } label: {
                Text("reader.preferences.layoutDirection", bundle: .module)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 132)
            .fixedSize()
        }
    }

    @ViewBuilder
    private var breakPolicyRow: some View {
        let binding = Binding<Bool>(
            get: { layoutModel.honorLayoutBreaks },
            set: { newValue in
                Task { await layoutModel.setHonorLayoutBreaks(newValue) }
            },
        )
        Toggle(isOn: binding) {
            Text("reader.preferences.honorBreaks", bundle: .module)
        }
    }

    private var collapseRow: some View {
        Toggle(isOn: $collapseMultiMeasureRests) {
            Text("reader.preferences.collapseMultiMeasureRests", bundle: .module)
        }
    }

    private var showInvisibleRow: some View {
        Toggle(isOn: $showInvisibleElements) {
            Text("reader.preferences.showInvisibleElements", bundle: .module)
        }
    }

    /// Toggles the bottom transport between the full-width seek-bar card and the compact pill. Shares the global
    /// `showSeekBarEnabled` store with the Settings sheet, so flipping it here mirrors there (and vice versa).
    private var seekBarRow: some View {
        Toggle(isOn: $showSeekBar) {
            Text("reader.inspector.showSeekBar", bundle: .module)
        }
    }

    /// Playback auto-follow opt-out. The label tracks the layout mode: scrolling modes read "auto-scroll", page mode
    /// reads "auto page turn".
    private var autoFollowRow: some View {
        Toggle(isOn: $autoFollowEnabled) {
            Text(
                layoutMode == .page
                    ? "reader.inspector.autoPageTurn"
                    : "reader.inspector.autoScroll",
                bundle: .module,
            )
        }
    }

    /// Page-mode tap-zone visibility opt-out. Only meaningful in `.page`, so the caller gates its presence on the mode.
    /// The caption reassures that turning the zones off does not disable swipe-to-turn, which stays available.
    private var pageTurnButtonsRow: some View {
        Toggle(isOn: $pageTurnButtonsVisible) {
            VStack(alignment: .leading, spacing: 4) {
                Text("reader.inspector.showPageTurnButtons", bundle: .module)
                Text("reader.inspector.showPageTurnButtons.footer", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var staffSizeRow: some View {
        let staffSize = Binding<Double>(
            get: { layoutModel.staffSize },
            set: { newValue in
                let current = layoutModel.staffSize
                if newValue > current {
                    Task { await layoutModel.incrementStaffSize() }
                } else if newValue < current {
                    Task { await layoutModel.decrementStaffSize() }
                }
            },
        )
        Stepper(
            value: staffSize,
            in: ReaderPreferences.minStaffSize ... ReaderPreferences.maxStaffSize,
            step: 1,
        ) {
            Text(String(
                localized: "reader.preferences.staffSize",
                defaultValue: "Staff size: \(Int(layoutModel.staffSize)) pt",
                bundle: .module,
            ))
        }
    }

    private func visualStaffRow(address: StaffAddress) -> some View {
        HStack(spacing: 8) {
            Spacer()
            clefMenu(address: address)
            StaffVisibilityButton(layoutModel: layoutModel, address: address)
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private func clefMenu(address: StaffAddress) -> some View {
        ClefMenu(layoutModel: layoutModel, address: address)
    }
}

extension View {
    /// iOS 18 fallback for `.listRowInsets(.vertical, _:)`, the iOS 26+ edge-specific overload used here and in
    /// `PlaybackInspectorScreen`. The classic `EdgeInsets`-based overload requires specifying every edge, and
    /// there's no public API to read the system's current default horizontal inset in order to preserve it exactly
    /// — so iOS 18 keeps the system's default row insets unchanged rather than guessing at a matching horizontal
    /// value. Not `fileprivate`: shared with `PlaybackInspectorScreen`, the other Reader screen using this overload.
    @ViewBuilder
    func verticalRowInsetCompat(_ length: CGFloat) -> some View {
        if #available(iOS 26, *) {
            listRowInsets(.vertical, length)
        } else {
            self
        }
    }
}

#if DEBUG
private func visualInspectorPreviewScore() -> Score {
    Score(division: 480, parts: [], metaTags: ["workTitle": "Sample"])
}

#Preview("Visual inspector · page") {
    UserDefaults.standard.set(ReaderLayoutMode.page.rawValue, forKey: ReaderGlobalSettingsKey.layoutMode)
    return VisualInspectorScreen(
        layoutModel: LayoutSettingsModel(),
        transposeModel: TransposeModel(),
        score: visualInspectorPreviewScore(),
    )
}

#Preview("Visual inspector · vertical") {
    UserDefaults.standard.set(ReaderLayoutMode.vertical.rawValue, forKey: ReaderGlobalSettingsKey.layoutMode)
    return VisualInspectorScreen(
        layoutModel: LayoutSettingsModel(),
        transposeModel: TransposeModel(),
        score: visualInspectorPreviewScore(),
    )
}
#endif
