// Sources/ImportExportShareUI/FileSummary.swift
import ImportExportAppGroup
import SwiftUI

struct FileSummary: View {
    let files: [IncomingShareIntent.File]
    let unsupportedCount: Int
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(headlineKey())
                .font(.headline)
            if !files.isEmpty {
                Button {
                    expanded.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .imageScale(.small)
                        Text(
                            expanded
                                ? "share_extension.summary.hide_files"
                                : "share_extension.summary.show_files",
                            bundle: .module,
                        )
                        .font(.subheadline)
                    }
                }
                .buttonStyle(.plain)

                if expanded {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(files, id: \.relativePath) { file in
                            Text(file.originalName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.leading, 12)
                }
            }
            if unsupportedCount > 0 {
                Label {
                    Text("share_extension.summary.unsupported_warning_\(unsupportedCount)", bundle: .module)
                        .font(.caption)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .foregroundStyle(.orange)
            }
        }
    }

    private func headlineKey() -> LocalizedStringResource {
        if files.count == 1 {
            return LocalizedStringResource(
                "share_extension.summary.one_score",
                bundle: .atURL(Bundle.module.bundleURL),
            )
        }
        return LocalizedStringResource(
            "share_extension.summary.n_scores_\(files.count)",
            bundle: .atURL(Bundle.module.bundleURL),
        )
    }
}
