// Sources/ImportExportShareUI/FileSummary.swift
import ImportExportAppGroup
import SwiftUI

struct FileSummary: View {
    let files: [IncomingShareIntent.File]
    let unsupportedCount: Int
    @State private var expanded = false

    var body: some View {
        Group {
            Text(headlineKey())
            if !files.isEmpty {
                DisclosureGroup(isExpanded: $expanded) {
                    ForEach(files, id: \.relativePath) { file in
                        Text(file.originalName)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } label: {
                    Text(
                        expanded
                            ? "share_extension.summary.hide_files"
                            : "share_extension.summary.show_files",
                        bundle: .module,
                    )
                    .font(.subheadline)
                }
            }
            if unsupportedCount > 0 {
                Label {
                    Text("share_extension.summary.unsupported_warning_\(unsupportedCount)", bundle: .module)
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
