import Domain
import SwiftUI
import UtilityUI

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
                if let soundfontResolver {
                    storageSection(resolver: soundfontResolver)
                }
                aboutSection
            }
            .navigationTitle(Text("settings.title", bundle: .module))
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
                .toolbar { doneToolbar }
                .sheet(isPresented: $isFeedbackMailPresented) {
                    FeedbackMailView(result: $feedbackMailResult)
                }
                .alert(
                    Text("settings.feedback.saved.title", bundle: .module),
                    isPresented: $isMailSavedAlertPresented
                ) {
                    Button(role: .cancel) {} label: { L10n.Common.ok }
                }
                .alert(
                    Text("settings.feedback.failed.title", bundle: .module),
                    isPresented: $isMailFailedAlertPresented
                ) {
                    Button(role: .cancel) {} label: { L10n.Common.ok }
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

    private func storageSection(resolver: any SoundfontResolver) -> some View {
        Section {
            NavigationLink {
                SoundfontCacheView(resolver: resolver, presetCatalog: presetCatalog)
            } label: {
                Label {
                    Text("settings.soundfont.title", bundle: .module)
                } icon: {
                    Image(systemName: "tray.full")
                }
            }
        } header: {
            Text("settings.storage.title", bundle: .module)
        }
    }

    private var aboutSection: some View {
        Section {
            NavigationLink {
                licenseContent()
                    .navigationTitle(Text("settings.about.licenses", bundle: .module))
                #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                #endif
            } label: {
                Label {
                    Text("settings.about.licenses", bundle: .module)
                } icon: {
                    Image(systemName: "doc.text")
                }
            }

            Button {
                isFeedbackMailPresented = true
            } label: {
                Label {
                    Text("settings.about.sendFeedback", bundle: .module)
                } icon: {
                    Image(systemName: "envelope")
                }
            }
            .disabled(!FeedbackMailView.canSendMail)
        } header: {
            Text("settings.about.title", bundle: .module)
        }
    }

    @ToolbarContentBuilder
    private var doneToolbar: some ToolbarContent {
        #if os(iOS)
            ToolbarItem(placement: .topBarTrailing) {
                Button { dismiss() } label: { L10n.Common.done }
            }
        #else
            ToolbarItem(placement: .automatic) {
                Button { dismiss() } label: { L10n.Common.done }
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
