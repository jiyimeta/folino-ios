import SwiftUI
import UtilityUI

struct InlineCreateRow: View {
    @Binding var name: String
    let placeholder: LocalizedStringKey
    let onCreate: (String) -> Void

    var body: some View {
        HStack {
            Image(systemName: "plus.circle.fill")
                .foregroundStyle(.tint)
            TextField(text: $name) { Text(placeholder, bundle: .module) }
                .submitLabel(.done)
                .onSubmit { commit() }
            Button { commit() } label: { L10n.Common.create }
                .buttonStyle(.borderless)
                .disabled(trimmed.isEmpty)
        }
    }

    private var trimmed: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commit() {
        let value = trimmed
        guard !value.isEmpty else { return }
        onCreate(value)
        name = ""
    }
}
