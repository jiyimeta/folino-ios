import Domain
import SwiftUI
import UtilityUI

/// Renders the Recently Deleted list. Rows expose:
/// * leading full-swipe → restore
/// * trailing partial-swipe → permanent-delete (with popover confirm)
/// * context menu → restore / permanent-delete (only those two) — on macOS, right-clicking inside a ⌘/⇧-click
///   selection of more than one row applies both to the whole selection instead of just that row
/// * tap → open in Reader
/// * ⌫ (macOS only) → permanent-delete the selection, with the same popover confirm
struct RecentlyDeletedView: View {
    let items: [ScoreItem]
    let onTap: (ScoreItem) -> Void
    let onRestore: (ScoreItem) -> Void
    let onRequestPermanentDelete: (ScoreItem) -> Void
    @Binding var pendingPermanentDelete: ScoreItem?
    let onConfirmPermanentDelete: (ScoreItem) -> Void
    @Binding var isSelecting: Bool
    @Binding var selectedIDs: Set<ScoreItemID>
    let onBulkRestore: () -> Void
    let onBulkPermanentDelete: () -> Void
    @Binding var isShowingBulkPermanentDeletePopover: Bool

    // PARITY(macos): bulk-selection chrome — iOS needs an explicit Select mode because a touch list cannot distinguish
    //   a tap-to-open from a tap-to-select. AppKit's List multi-selects natively with ⌘/⇧-click, so the Mac has no mode
    //   and reaches the same bulk actions from a context menu on the selection and ⌫ (Task 14) — only the menu bar
    //   (sub-project Ⅳ) is still open.
    var body: some View {
        List(selection: $selectedIDs) {
            ForEach(items) { item in
                row(for: item)
                    .tag(item.id)
            }
        }
        .bulkSelectionEditModeCompat(isSelecting: isSelecting)
        .popoverCompat(isPresented: $isShowingBulkPermanentDeletePopover) {
            bulkPermanentDeletePopoverContent
        }
        .deleteCommandCompat {
            guard !selectedIDs.isEmpty else { return }
            isShowingBulkPermanentDeletePopover = true
        }
        .safeAreaInset(edge: .bottom) {
            #if os(iOS)
            if isSelecting {
                RecentlyDeletedBulkActionBar(
                    selectionCount: selectedIDs.count,
                    onRestore: onBulkRestore,
                    isShowingPermanentDeletePopover: $isShowingBulkPermanentDeletePopover,
                    onConfirmPermanentDelete: onBulkPermanentDelete,
                )
            }
            #endif
        }
    }

    private func row(for item: ScoreItem) -> some View {
        HStack(spacing: 0) {
            ScoreRow(scoreItem: item)
                .contentShape(Rectangle())
                .onTapGesture { handleRowTap(item) }
            if !isSelecting {
                Menu {
                    rowContextMenu(for: item)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 34)
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.Common.more)
            }
        }
        .swipeActionsCompat(edge: .leading, allowsFullSwipe: true) { restoreSwipeButton(for: item) }
        // Full swipe disabled — accidental hard-deletes here are unrecoverable, so require a deliberate tap that
        // triggers the popover confirm.
        .swipeActionsCompat(edge: .trailing, allowsFullSwipe: false) {
            permanentDeleteSwipeButton(for: item)
        }
        .contextMenu { effectiveRowContextMenu(for: item) }
        // Anchor the popover so its arrow points UP at the row — on iPhone the row spans the full width, so a
        // leading/trailing anchor would push the popover off-screen. `.top` floats it below the row, centered
        // horizontally, which fits in compact widths.
        .popover(
            isPresented: rowPopoverBinding(for: item),
            attachmentAnchor: .rect(.bounds),
            arrowEdge: .top,
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

    /// The row's own restore/permanent-delete pair, unless this row is part of a multi-item selection — right-clicking
    /// anywhere inside a ⌘/⇧-click selection then offers the bulk actions instead, mirroring how AppKit list views
    /// resolve a selection-vs-single-item context menu. A single selected row keeps the row's own menu, which is
    /// already the same two actions.
    @ViewBuilder
    private func effectiveRowContextMenu(for item: ScoreItem) -> some View {
        #if os(macOS)
        if selectedIDs.contains(item.id), selectedIDs.count > 1 {
            bulkRowContextMenuContent
        } else {
            rowContextMenu(for: item)
        }
        #else
        rowContextMenu(for: item)
        #endif
    }

    #if os(macOS)
    /// The same two actions `RecentlyDeletedBulkActionBar` offers on iOS, applied to the whole selection.
    @ViewBuilder
    private var bulkRowContextMenuContent: some View {
        Button {
            onBulkRestore()
        } label: {
            Label {
                Text("library.recentlyDeleted.restore.action", bundle: .module)
            } icon: {
                Image(systemName: "arrow.uturn.backward")
            }
        }
        Button(role: .destructive) {
            isShowingBulkPermanentDeletePopover = true
        } label: {
            Label {
                Text("library.recentlyDeleted.delete.action", bundle: .module)
            } icon: {
                Image(systemName: "trash.fill")
            }
        }
    }
    #endif

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

    /// Mirrors `RecentlyDeletedBulkActionBar.bulkPopoverContent` for the macOS-only `.popoverCompat` confirmation,
    /// reusing the same xcstrings keys — declared unconditionally (not `#if os(macOS)`) because the modifier chain
    /// in `body` references it unconditionally; `popoverCompat` is what makes the reference inert on iOS.
    private var bulkPermanentDeletePopoverContent: some View {
        PermanentDeletePopover(
            title: Text(String(
                localized: "library.recentlyDeleted.deleteBulk.confirm.title",
                defaultValue: "Permanently delete \(selectedIDs.count) scores?",
                bundle: .module,
            )),
            message: Text("library.recentlyDeleted.deleteBulk.confirm.message", bundle: .module),
            confirmLabel: Text("library.recentlyDeleted.delete.action", bundle: .module),
            onConfirm: {
                isShowingBulkPermanentDeletePopover = false
                onBulkPermanentDelete()
            },
            onCancel: { isShowingBulkPermanentDeletePopover = false },
        )
        .presentationCompactAdaptation(.popover)
    }

    private func handleRowTap(_ item: ScoreItem) {
        if isSelecting {
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

extension View {
    /// `.swipeActions` on iOS; a no-op on macOS, which has no touch-swipe gesture and so no meaning for these — the
    /// restore / permanent-delete pair is always reachable from the row's context menu too, so nothing is lost.
    ///
    /// A helper rather than an inline `#if` because these calls sit inside a modifier chain (`.swipeActionsCompat(...)
    /// .swipeActionsCompat(...).contextMenu(...).popover(...)`), and SwiftFormat's `--ifdef no-indent` de-indents the
    /// whole chain when a `#if` interrupts one of its links.
    @ViewBuilder
    func swipeActionsCompat<Content: View>(
        edge: HorizontalEdge,
        allowsFullSwipe: Bool,
        @ViewBuilder content: () -> Content,
    ) -> some View {
        #if os(iOS)
        swipeActions(edge: edge, allowsFullSwipe: allowsFullSwipe, content: content)
        #else
        self
        #endif
    }

    /// Presents `content` as a popover, macOS only, anchored to whichever view this is attached to — the macOS-only
    /// bulk permanent-delete confirmation. A no-op on iOS, which drives the same confirmation from
    /// `RecentlyDeletedBulkActionBar`'s own popover instead.
    ///
    /// A helper rather than an inline `#if` for the same reason as `swipeActionsCompat` above: this sits inside a
    /// modifier chain, and SwiftFormat's `--ifdef no-indent` de-indents the whole chain when a `#if` interrupts one
    /// of its links.
    @ViewBuilder
    func popoverCompat<Content: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content,
    ) -> some View {
        #if os(macOS)
        popover(isPresented: isPresented) {
            content()
        }
        #else
        self
        #endif
    }
}
