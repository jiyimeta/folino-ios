import Domain
import SwiftUI
import UtilityUI

struct TagDetailView<Content: View>: View {
    let tagName: String
    let onRename: (String) -> Void
    let onDelete: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .navigationTitle(tagName)
            .manageEntityToolbar(
                entityName: tagName,
                copy: .tag,
                onRename: onRename,
                onDelete: onDelete,
            )
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        TagDetailView(
            tagName: "Practice",
            onRename: { _ in },
            onDelete: {},
        ) {
            List {
                Text("Score A")
                Text("Score B")
            }
        }
    }
}
#endif
