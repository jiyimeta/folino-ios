import Domain
import SwiftUI

@MainActor
public struct SettingsSheet<LicenseContent: View>: View {
    private let licenseContent: () -> LicenseContent
    private let soundfontResolver: (any SoundfontResolver)?
    private let presetCatalog: (any SoundfontPresetCatalog)?
    @Environment(\.dismiss) private var dismiss
    @State private var isFeedbackMailPresented = false
    @State private var feedbackMailResult: FeedbackMailComposeResult?
    @State private var isMailSavedAlertPresented = false
    @State private var isMailFailedAlertPresented = false

    @AppStorage(ReaderGlobalSettingsKey.metronomeEnabled)
    private var isMetronomeEnabled: Bool = false

    @AppStorage(ReaderGlobalSettingsKey.layoutMode)
    private var layoutModeRaw: String = ReaderLayoutMode.vertical.rawValue

    public init(
        soundfontResolver: (any SoundfontResolver)? = nil,
        presetCatalog: (any SoundfontPresetCatalog)? = nil,
        @ViewBuilder licenseContent: @escaping () -> LicenseContent
    ) {
        self.soundfontResolver = soundfontResolver
        self.presetCatalog = presetCatalog
        self.licenseContent = licenseContent
    }

    public var body: some View {
        NavigationStack {
            Form {
                readerSection
                if let soundfontResolver {
                    storageSection(resolver: soundfontResolver)
                }
                aboutSection
            }
            .navigationTitle(Text("Settings", bundle: .module))
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
                .toolbar { doneToolbar }
                .sheet(isPresented: $isFeedbackMailPresented) {
                    FeedbackMailView(result: $feedbackMailResult)
                }
                .alert("Mail Saved to Drafts", isPresented: $isMailSavedAlertPresented) {
                    Button("OK", role: .cancel) {}
                }
                .alert("Mail Delivery Failed", isPresented: $isMailFailedAlertPresented) {
                    Button("OK", role: .cancel) {}
                }
                .onChange(of: feedbackMailResult) { _, newValue in
                    switch newValue {
                    case .saved:
                        isMailSavedAlertPresented = true
                    case .failed:
                        isMailFailedAlertPresented = true
                    case .cancelled, .sent, nil:
                        break
                    }
                }
        }
    }

    private var readerSection: some View {
        Section {
            Toggle(isOn: $isMetronomeEnabled) {
                Label {
                    Text("Metronome", bundle: .module)
                } icon: {
                    Image(systemName: isMetronomeEnabled ? "metronome.fill" : "metronome")
                }
            }

            Picker(selection: $layoutModeRaw) {
                Label {
                    Text("Vertical", bundle: .module)
                } icon: {
                    Image(systemName: "arrow.up.and.down")
                }
                .tag(ReaderLayoutMode.vertical.rawValue)

                Label {
                    Text("Horizontal", bundle: .module)
                } icon: {
                    Image(systemName: "arrow.left.and.right")
                }
                .tag(ReaderLayoutMode.horizontal.rawValue)
            } label: {
                Label {
                    Text("Layout direction", bundle: .module)
                } icon: {
                    Image(systemName: "rectangle.split.1x2")
                }
            }
        } header: {
            Text("Reader", bundle: .module)
        }
    }

    private func storageSection(resolver: any SoundfontResolver) -> some View {
        Section {
            NavigationLink {
                SoundfontCacheView(resolver: resolver, presetCatalog: presetCatalog)
            } label: {
                Label {
                    Text("Soundfont Cache", bundle: .module)
                } icon: {
                    Image(systemName: "tray.full")
                }
            }
        } header: {
            Text("Storage", bundle: .module)
        }
    }

    private var aboutSection: some View {
        Section {
            NavigationLink {
                licenseContent()
                    .navigationTitle(Text("Licenses", bundle: .module))
                #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                #endif
            } label: {
                Label {
                    Text("Licenses", bundle: .module)
                } icon: {
                    Image(systemName: "doc.text")
                }
            }

            Button {
                isFeedbackMailPresented = true
            } label: {
                Label {
                    Text("Send Feedback", bundle: .module)
                } icon: {
                    Image(systemName: "envelope")
                }
            }
            .disabled(!FeedbackMailView.canSendMail)
        } header: {
            Text("About", bundle: .module)
        }
    }

    @ToolbarContentBuilder
    private var doneToolbar: some ToolbarContent {
        #if os(iOS)
            ToolbarItem(placement: .topBarTrailing) {
                Button { dismiss() } label: { Text("Done", bundle: .module) }
            }
        #else
            ToolbarItem(placement: .automatic) {
                Button { dismiss() } label: { Text("Done", bundle: .module) }
            }
        #endif
    }
}

#Preview("Without resolver") {
    SettingsSheet { Text("License placeholder") }
}

#Preview("With resolver") {
    SettingsSheet(soundfontResolver: PreviewResolver()) {
        Text("License placeholder")
    }
}

private struct PreviewResolver: SoundfontResolver {
    func resolveSoundfont(bank _: Int, program _: Int, isDrums _: Bool) throws -> URL {
        URL(fileURLWithPath: "/dev/null")
    }

    func cachedPatches() throws -> [SoundfontPatch] { [] }
    func totalCacheSizeBytes() throws -> Int64 { 0 }
    func deletePatch(bank _: Int, program _: Int, isDrums _: Bool) throws {}
    func clearCache() throws {}
}
