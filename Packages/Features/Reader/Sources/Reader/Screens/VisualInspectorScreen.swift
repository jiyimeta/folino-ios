import Domain
import SheetMusicAudio
import SheetMusicCore
import SwiftUI

struct VisualInspectorScreen: View {
    let layoutModel: LayoutSettingsModel
    let score: Score

    @AppStorage(ReaderGlobalSettingsKey.layoutMode)
    private var layoutModeRaw: String = ReaderLayoutMode.page.rawValue

    @AppStorage(ReaderGlobalSettingsKey.collapseMultiMeasureRests)
    private var collapseMultiMeasureRests = false

    @AppStorage(ReaderGlobalSettingsKey.showInvisibleElements)
    private var showInvisibleElements = false

    var body: some View {
        List {
            // Top-of-list "general" controls intentionally render without a section header — they apply to the whole
            // score and the header would only repeat that with no information value.
            layoutRow
            staffSizeRow
            breakPolicyRow
            collapseRow
            showInvisibleRow

            Section {
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
                    .listRowInsets(.vertical, 6)
                }
            } header: {
                Text("reader.inspector.section.parts", bundle: .module)
            }
        }
        .buttonStyle(.plain)
    }

    private var layoutRow: some View {
        HStack {
            Text("reader.preferences.layoutDirection", bundle: .module)
            Spacer()
            Picker(selection: $layoutModeRaw) {
                Image(systemName: "arrow.up.and.down")
                    .tag(ReaderLayoutMode.vertical.rawValue)
                Image(systemName: "arrow.left.and.right")
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
            visibilityButton(address: address)
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private func clefMenu(address: StaffAddress) -> some View {
        ClefMenu(layoutModel: layoutModel, address: address)
    }

    @ViewBuilder
    func visibilityButton(address: StaffAddress) -> some View {
        let isVisible = !layoutModel.hiddenStaves.contains(address)

        Button {
            Task { await layoutModel.toggleStaff(address) }
        } label: {
            EyeIcon(isOpen: isVisible, lineWidth: 2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28, height: 24)
        }
        .contentShape(.rect)
        .animation(.spring(duration: 0.18), value: isVisible)
    }
}
