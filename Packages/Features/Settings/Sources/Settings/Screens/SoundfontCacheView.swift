import Domain
import SwiftUI
import UtilityUI

@MainActor
struct SoundfontCacheView: View {
    let resolver: any SoundfontResolver
    let presetCatalog: (any SoundfontPresetCatalog)?

    @State private var patches: [SoundfontPatch] = []
    @State private var totalBytes: Int64 = 0
    @State private var loadError: String?
    @State private var isLoading = true
    @State private var showDeleteAllConfirmation = false

    private static let byteFormat: ByteCountFormatStyle = .byteCount(style: .file)

    var body: some View {
        Group {
            if isLoading {
                ProgressView().controlSize(.regular)
            } else if let loadError {
                ContentUnavailableView {
                    Label {
                        Text("settings.soundfont.error.title", bundle: .module)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                } description: {
                    Text(loadError)
                }
            } else if patches.isEmpty {
                ContentUnavailableView {
                    Label {
                        Text("settings.soundfont.empty.title", bundle: .module)
                    } icon: {
                        Image(systemName: "tray")
                    }
                } description: {
                    Text("settings.soundfont.empty.hint", bundle: .module)
                }
            } else {
                cacheList
            }
        }
        .navigationTitle(Text("settings.soundfont.title", bundle: .module))
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
            .task { await reload() }
            .confirmationDialog(
                Text("settings.soundfont.deleteAll.title", bundle: .module),
                isPresented: $showDeleteAllConfirmation,
                titleVisibility: .visible
            ) {
                Button(role: .destructive) {
                    Task { await deleteAll() }
                } label: {
                    Text("settings.soundfont.deleteAll.button", bundle: .module)
                }
                Button(role: .cancel) {} label: { L10n.Common.cancel }
            } message: {
                Text("settings.soundfont.deleteAll.message", bundle: .module)
            }
    }

    private var cacheList: some View {
        List {
            Section {
                LabeledContent {
                    Text(totalBytes.formatted(Self.byteFormat))
                        .monospacedDigit()
                } label: {
                    Text("settings.soundfont.total", bundle: .module)
                }
                Button(role: .destructive) {
                    showDeleteAllConfirmation = true
                } label: {
                    Label {
                        Text("settings.soundfont.deleteAll.action", bundle: .module)
                    } icon: {
                        Image(systemName: "trash")
                    }
                }
            }
            Section {
                ForEach(patches) { patch in
                    row(for: patch)
                }
                .onDelete { indexSet in
                    Task { await deletePatches(at: indexSet) }
                }
            } header: {
                Text("settings.soundfont.cached.title", bundle: .module)
            }
        }
    }

    private func row(for patch: SoundfontPatch) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName(for: patch))
                Text(patch.localFileName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(patch.sizeBytes.formatted(Self.byteFormat))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private func displayName(for patch: SoundfontPatch) -> String {
        if let name = presetCatalog?.presetName(bank: patch.bank, program: patch.program) {
            return name
        }
        return GMProgramName.displayName(bank: patch.bank, program: patch.program)
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let fetched = try await resolver.cachedPatches()
                .filter { !$0.isBundled }
                .sorted { lhs, rhs in
                    if lhs.sizeBytes != rhs.sizeBytes {
                        return lhs.sizeBytes > rhs.sizeBytes
                    }
                    return (lhs.bank, lhs.program) < (rhs.bank, rhs.program)
                }
            patches = fetched
            totalBytes = fetched.reduce(0) { $0 + $1.sizeBytes }
            loadError = nil
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    private func deletePatches(at offsets: IndexSet) async {
        let targets = offsets.map { patches[$0] }
        for patch in targets {
            try? await resolver.deletePatch(
                bank: patch.bank, program: patch.program, isDrums: patch.isDrums
            )
        }
        await reload()
    }

    private func deleteAll() async {
        try? await resolver.clearCache()
        await reload()
    }
}

#Preview {
    NavigationStack {
        SoundfontCacheView(
            resolver: PreviewSoundfontResolver(),
            presetCatalog: PreviewPresetCatalog()
        )
    }
}

private struct PreviewPresetCatalog: SoundfontPresetCatalog {
    func presetName(bank: Int, program: Int) -> String? {
        switch (bank, program) {
        case (17, 43): "Contrabass Expr."
        default: nil
        }
    }
}

private struct PreviewSoundfontResolver: SoundfontResolver {
    func resolveSoundfont(bank _: Int, program _: Int, isDrums _: Bool) throws -> URL {
        URL(fileURLWithPath: "/dev/null")
    }

    func cachedPatches() throws -> [SoundfontPatch] {
        let now = Date()
        return [
            SoundfontPatch(
                bank: 0, program: 0, localFileName: "000_000.sf2",
                sizeBytes: 3_412_009, downloadedAt: now, lastUsedAt: now
            ),
            SoundfontPatch(
                bank: 0, program: 24, localFileName: "000_024.sf2",
                sizeBytes: 1_204_882, downloadedAt: now, lastUsedAt: now
            ),
            SoundfontPatch(
                bank: 128, program: 0, localFileName: "128_000.sf2",
                sizeBytes: 8_122_044, downloadedAt: now, lastUsedAt: now
            ),
            SoundfontPatch(
                bank: 17, program: 43, localFileName: "017_043.sf2",
                sizeBytes: 740_512, downloadedAt: now, lastUsedAt: now
            ),
        ]
    }

    func totalCacheSizeBytes() throws -> Int64 { 12_738_935 }
    func deletePatch(bank _: Int, program _: Int, isDrums _: Bool) throws {}
    func clearCache() throws {}
}
