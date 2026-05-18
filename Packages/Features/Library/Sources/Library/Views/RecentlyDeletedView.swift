import Domain
import SwiftUI
import UtilityUI

/// Renders the Recently Deleted list. Rows expose:
/// * leading full-swipe → restore
/// * trailing partial-swipe → permanent-delete (with popover confirm)
/// * context menu → restore / permanent-delete (only those two)
/// * tap → open in Reader
struct RecentlyDeletedView: View {
    let items: [ScoreItem]
    let onTap: (ScoreItem) -> Void
    let onRestore: (ScoreItem) -> Void
    let onRequestPermanentDelete: (ScoreItem) -> Void
    @Binding var pendingPermanentDelete: ScoreItem?
    let onConfirmPermanentDelete: (ScoreItem) -> Void
    @Binding var editMode: EditMode
    @Binding var selectedIDs: Set<ScoreItemID>
    let onBulkRestore: () -> Void
    let onBulkPermanentDelete: () -> Void
    @Binding var isShowingBulkPermanentDeletePopover: Bool

    var body: some View {
        List(selection: $selectedIDs) {
            ForEach(items) { item in
                row(for: item)
                    .tag(item.id)
            }
        }
        .environment(\.editMode, $editMode)
        .safeAreaInset(edge: .bottom) {
            if editMode.isEditing {
                RecentlyDeletedBulkActionBar(
                    selectionCount: selectedIDs.count,
                    onRestore: onBulkRestore,
                    isShowingPermanentDeletePopover: $isShowingBulkPermanentDeletePopover,
                    onConfirmPermanentDelete: onBulkPermanentDelete,
                )
            }
        }
    }

    private func row(for item: ScoreItem) -> some View {
        ScoreRow(scoreItem: item)
            .contentShape(Rectangle())
            .onTapGesture { handleRowTap(item) }
            .swipeActions(edge: .leading, allowsFullSwipe: true) { restoreSwipeButton(for: item) }
            // Full swipe disabled — accidental hard-deletes here are
            // unrecoverable, so require a deliberate tap that triggers the
            // popover confirm.
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                permanentDeleteSwipeButton(for: item)
            }
            .contextMenu { rowContextMenu(for: item) }
            .popover(
                isPresented: rowPopoverBinding(for: item),
                attachmentAnchor: .rect(.bounds),
                arrowEdge: .trailing,
            ) {
                rowPopoverContent(for: item)
            }
    }

    private func restoreSwipeButton(for item: ScoreItem) -> some View {
        Button {
            onRestore(item)
        } label: {
            Label {
                Text("library.recentlyDeleted.restore.action", bundle: .module)
            } icon: {
                Image(systemName: "arrow.uturn.backward")
            }
        }
        .tint(.green)
    }

    private func permanentDeleteSwipeButton(for item: ScoreItem) -> some View {
        Button {
            onRequestPermanentDelete(item)
        } label: {
            Label {
                Text("library.recentlyDeleted.delete.action", bundle: .module)
            } icon: {
                Image(systemName: "trash.fill")
            }
        }
        .tint(.red)
    }

    @ViewBuilder
    private func rowContextMenu(for item: ScoreItem) -> some View {
        Button {
            onRestore(item)
        } label: {
            Label {
                Text("library.recentlyDeleted.restore.action", bundle: .module)
            } icon: {
                Image(systemName: "arrow.uturn.backward")
            }
        }
        Button(role: .destructive) {
            onRequestPermanentDelete(item)
        } label: {
            Label {
                Text("library.recentlyDeleted.delete.action", bundle: .module)
            } icon: {
                Image(systemName: "trash.fill")
            }
        }
    }

    private func rowPopoverContent(for item: ScoreItem) -> some View {
        PermanentDeletePopover(
            title: Text(String(
                localized: "library.recentlyDeleted.delete.confirm.title",
                defaultValue: "Permanently delete \"\(item.title)\"?",
                bundle: .module,
            )),
            message: Text("library.recentlyDeleted.delete.confirm.message", bundle: .module),
            confirmLabel: Text("library.recentlyDeleted.delete.action", bundle: .module),
            onConfirm: {
                onConfirmPermanentDelete(item)
                pendingPermanentDelete = nil
            },
            onCancel: { pendingPermanentDelete = nil },
        )
        .presentationCompactAdaptation(.popover)
    }

    private func handleRowTap(_ item: ScoreItem) {
        if editMode.isEditing {
            toggleSelection(item.id)
        } else {
            onTap(item)
        }
    }

    private func rowPopoverBinding(for item: ScoreItem) -> Binding<Bool> {
        Binding(
            get: { pendingPermanentDelete?.id == item.id },
            set: { isPresented in
                if !isPresented, pendingPermanentDelete?.id == item.id {
                    pendingPermanentDelete = nil
                }
            },
        )
    }

    private func toggleSelection(_ id: ScoreItemID) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }
}

/// Shared popover layout for both the row and the bulk button.
struct PermanentDeletePopover: View {
    let title: Text
    let message: Text
    let confirmLabel: Text
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            title.font(.headline)
            message.font(.subheadline).foregroundStyle(.secondary)
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
        .frame(minWidth: 280, idealWidth: 320)
    }
}

/// Bottom bar shown in edit mode of the Recently Deleted screen. Only two
/// actions: Restore and Permanently Delete; the latter anchors a popover
/// confirmation to itself.
private struct RecentlyDeletedBulkActionBar: View {
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
