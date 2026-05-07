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
                    storageSection(resolver: soundfontResolver)
                }
                aboutSection
            }
            .navigationTitle(Text("Settings", bundle: .module))
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
                .toolbar { doneToolbar }
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
