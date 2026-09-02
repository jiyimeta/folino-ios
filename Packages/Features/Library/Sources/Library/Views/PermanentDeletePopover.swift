import SwiftUI
import UtilityUI

/// Shared popover layout for both the row and the bulk button.
struct PermanentDeletePopover: View {
    let title: Text
    let message: Text
    let confirmLabel: Text
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            title
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            message
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button(role: .cancel) {
                    onCancel()
                } label: {
                    L10n.Common.cancel
                        .frame(maxWidth: .infinity)
                }
                Button(role: .destructive) {
                    onConfirm()
                } label: {
                    confirmLabel.frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
        .padding(20)
        // 260 fits inside a compact-width iPhone (≈ 390pt – screen margins), while idealWidth gives Mac / iPad popovers
        // a comfortable layout.
        .frame(minWidth: 260, idealWidth: 300, maxWidth: 360)
    }
}

/// Bottom bar shown in edit mode of the Recently Deleted screen. Only two actions: Restore and Permanently Delete; the
/// latter anchors a popover confirmation to itself.
struct RecentlyDeletedBulkActionBar: View {
    let selectionCount: Int
    let onRestore: () -> Void
    @Binding var isShowingPermanentDeletePopover: Bool
    let onConfirmPermanentDelete: () -> Void

    var body: some View {
        HStack(spacing: 24) {
            restoreButton
            Spacer()
            deleteButton
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var restoreButton: some View {
        Button {
            onRestore()
        } label: {
            Label {
                Text("library.recentlyDeleted.restore.action", bundle: .module)
            } icon: {
                Image(systemName: "arrow.uturn.backward")
            }
        }
        .disabled(selectionCount == 0)
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            isShowingPermanentDeletePopover = true
        } label: {
            Label {
                Text("library.recentlyDeleted.delete.action", bundle: .module)
            } icon: {
                Image(systemName: "trash.fill")
            }
        }
        .disabled(selectionCount == 0)
        .popover(
            isPresented: $isShowingPermanentDeletePopover,
            attachmentAnchor: .rect(.bounds),
            arrowEdge: .bottom,
        ) {
            bulkPopoverContent
        }
    }

    private var bulkPopoverContent: some View {
        PermanentDeletePopover(
            title: Text(String(
                localized: "library.recentlyDeleted.deleteBulk.confirm.title",
                defaultValue: "Permanently delete \(selectionCount) scores?",
                bundle: .module,
            )),
            message: Text("library.recentlyDeleted.deleteBulk.confirm.message", bundle: .module),
            confirmLabel: Text("library.recentlyDeleted.delete.action", bundle: .module),
            onConfirm: {
                isShowingPermanentDeletePopover = false
                onConfirmPermanentDelete()
            },
            onCancel: { isShowingPermanentDeletePopover = false },
        )
        .presentationCompactAdaptation(.popover)
    }
}

#if DEBUG
#Preview("Popover (long ja title)") {
    PermanentDeletePopover(
        title: Text("「Now_is_the_time」を完全に削除しますか？"),
        message: Text("このスコアとファイルがこの端末から削除されます。"),
        confirmLabel: Text("完全に削除"),
        onConfirm: {},
        onCancel: {},
    )
}

#Preview("Popover (en)") {
    PermanentDeletePopover(
        title: Text("Permanently delete \"Now is the time\"?"),
        message: Text("This score and its file will be removed from this device."),
        confirmLabel: Text("Permanently Delete"),
        onConfirm: {},
        onCancel: {},
    )
}
#endif
