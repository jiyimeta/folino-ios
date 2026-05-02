import SwiftUI

@MainActor
public struct SettingsSheet<LicenseContent: View>: View {
    private let licenseContent: () -> LicenseContent
    @Environment(\.dismiss) private var dismiss

    public init(@ViewBuilder licenseContent: @escaping () -> LicenseContent) {
        self.licenseContent = licenseContent
    }

    public var body: some View {
        NavigationStack {
            Form {
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

#Preview {
    SettingsSheet { Text("License placeholder") }
}
