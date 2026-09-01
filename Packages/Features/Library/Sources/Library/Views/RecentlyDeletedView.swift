import Domain
import SwiftUI
import UtilityUI

/// Renders the Recently Deleted list. Rows expose:
/// * leading full-swipe → restore
/// * trailing partial-swipe → permanent-delete (with popover confirm)
/// * context menu → restore / permanent-delete (only those two) — on macOS, right-clicking inside a ⌘/⇧-click
///   selection of more than one row applies both to the whole selection instead of just that row
/// * tap → open in Reader (iOS). On macOS there is no row gesture — opening is its own action (double-click, Return,
///   or a context-menu item), never a side effect of selection; see `RowOpenAffordance`
/// * ⌫ (macOS only) → permanent-delete the selection, with the same popover confirm
struct RecentlyDeletedView: View {
    let items: [ScoreItem]
    let onTap: (ScoreItem) -> Void
    /// **macOS only**, in effect — see `ScoreListView.onOpenInNewWindow`.
    let onOpenInNewWindow: (ScoreItem) -> Void
    let onRestore: (ScoreItem) -> Void
    let onRequestPermanentDelete: (ScoreItem) -> Void
    @Binding var pendingPermanentDelete: ScoreItem?
    let onConfirmPermanentDelete: (ScoreItem) -> Void
    @Binding var isSelecting: Bool
    @Binding var selectedIDs: Set<ScoreItemID>
    let onBulkRestore: () -> Void
    let onBulkPermanentDelete: () -> Void
    @Binding var isShowingBulkPermanentDeletePopover: Bool

    // PARITY(macos): bulk-selection chrome — iOS needs an explicit Select mode because a touch list cannot
    //   distinguish a tap-to-open from a tap-to-select. macOS needs no mode: `List(selection:)` multi-selects
    //   with ⌘/⇧-click, the same bulk actions come from a context menu on the selection, and ⌫ deletes it.
    //   That works ONLY because the row carries no tap gesture there — any SwiftUI tap gesture leaves the
    //   selection permanently EMPTY, which silently made the context menu and ⌫ unreachable for two tasks
    //   before it was measured. Opening is its own action now, never a side effect of selecting a row — see
    //   `RowOpenAffordance` for the measurement and for both halves of the per-platform decision. Still open: the
    //   menu bar (Ⅳ).
    var body: some View {
        List(selection: $selectedIDs) {
            ForEach(items) { item in
                row(for: item)
                    .tag(item.id)
            }
        }
        .macScoreOpenAffordance(selectedIDs, in: items, onOpen: onTap, onOpenInNewWindow: onOpenInNewWindow)
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
                .rowTapToOpenCompat { handleRowTap(item) }
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
        // Raw `.swipeActions`, not a compat helper: the modifier is macOS 12+, so it compiles on both platforms and
        // is simply inert where there is no touch swipe. `ScoreListRow` in this same package calls it raw twice and
        // builds for macOS.
        .swipeActions(edge: .leading, allowsFullSwipe: true) { restoreSwipeButton(for: item) }
        // Full swipe disabled — accidental hard-deletes here are unrecoverable, so require a deliberate tap that
        // triggers the popover confirm.
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
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
    ///
    /// On macOS, Open / Open in New Window are prepended here too — this row has no tap gesture and no pre-existing
    /// "Open" menu item to extend, so both come from this file rather than from a shared builder; see
    /// `macScoreOpenAffordance`'s doc comment for why they live in the row's own menu and not in a second one.
    @ViewBuilder
    private func effectiveRowContextMenu(for item: ScoreItem) -> some View {
        #if os(macOS)
        if selectedIDs.contains(item.id), selectedIDs.count > 1 {
            bulkRowContextMenuContent
        } else {
            openRowContextMenuContent(for: item)
            Divider()
            rowContextMenu(for: item)
        }
        #else
        rowContextMenu(for: item)
        #endif
    }

    #if os(macOS)
    @ViewBuilder
    private func openRowContextMenuContent(for item: ScoreItem) -> some View {
        Button { onTap(item) } label: {
            Label {
                L10n.Common.open
            } icon: {
                Image(systemName: "music.note")
            }
        }
        Button { onOpenInNewWindow(item) } label: {
            Label {
                Text("library.open.newWindow", bundle: .module)
            } icon: {
                Image(systemName: "macwindow")
            }
        }
    }

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
