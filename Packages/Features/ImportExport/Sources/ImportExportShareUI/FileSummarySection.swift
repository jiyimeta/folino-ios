import ImportExportAppGroup
import SwiftUI
import UtilityUI

struct FileSummarySection: View {
    let files: [IncomingShareIntent.File]
    let unsupportedCount: Int
    @State private var expanded = true

    var body: some View {
        CollapsibleSection(isExpanded: $expanded, count: files.count) {
            ForEach(files, id: \.relativePath) { file in
                Text(file.originalName)
                    .lineLimit(1)
            }
        } header: {
            Text(LocalizedStringResource(
                files.count == 1
                    ? "share_extension.summary.file_to_add"
                    : "share_extension.summary.files_to_add",
                bundle: .module,
            ))
        } footer: { _ in
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
}

#Preview {
    Form {
        FileSummarySection(
            files: [
                IncomingShareIntent.File(relativePath: "path/to/foo.mscz", originalName: "foo.mscz"),
                IncomingShareIntent.File(relativePath: "path/to/bar.mscz", originalName: "bar.mscz"),
            ],
            unsupportedCount: 2,
        )
    }
}
