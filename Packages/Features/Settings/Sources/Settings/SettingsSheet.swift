import Domain
import SwiftUI

@MainActor
public struct SettingsSheet<LicenseContent: View>: View {
    private let licenseContent: () -> LicenseContent
    private let soundfontResolver: (any SoundfontResolver)?
    private let presetCatalog: (any SoundfontPresetCatalog)?
    @Environment(\.dismiss) private var dismiss

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
                    Section("Storage") {
                        NavigationLink {
                            SoundfontCacheView(
                                resolver: soundfontResolver,
                                presetCatalog: presetCatalog
                            )
                        } label: {
                            Label("Soundfont Cache", systemImage: "tray.full")
                        }
                    }
                }
                Section("About") {
                    NavigationLink {
                        licenseContent()
                            .navigationTitle("Licenses")
                        #if os(iOS)
                            .navigationBarTitleDisplayMode(.inline)
                        #endif
                    } label: {
                        Label("Licenses", systemImage: "doc.text")
                    }
                }
            }
            .navigationTitle("Settings")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
                .toolbar { doneToolbar }
        }
    }

    @ToolbarContentBuilder
    private var doneToolbar: some ToolbarContent {
        #if os(iOS)
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
            }
        #else
            ToolbarItem(placement: .automatic) {
                Button("Done") { dismiss() }
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
