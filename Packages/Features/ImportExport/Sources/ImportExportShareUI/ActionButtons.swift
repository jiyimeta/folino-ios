// Sources/ImportExportShareUI/ActionButtons.swift
import SwiftUI

struct ActionButtons: View {
    let disabled: Bool
    let onSave: () -> Void
    let onSaveAndOpen: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onSave) {
                Text("share_extension.action.save", bundle: .module)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.bordered)
            .disabled(disabled)

            Button(action: onSaveAndOpen) {
                Text("share_extension.action.save_and_open", bundle: .module)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .disabled(disabled)
        }
    }
}
