import Domain
import Editor
import Reader
import UtilityCore

/// Connects a `ReaderEditingHost` (Reader → App) to an `EditorViewModel` (App → Editor). The ONLY place the two
/// features meet, shared by the iOS `EditableReaderScreen` and the Mac `MacEditableReaderScreen` so the closures can
/// never drift between the two shells. Call it exactly once per host / view-model pair.
@MainActor
func wireEditingSeam(
    host: ReaderEditingHost,
    viewModel vm: EditorViewModel,
    repository: any ScoreLibraryRepository,
    analytics: any Analytics,
) {
    host.onBeginEditing = { [weak vm, weak host, repository] score in
        guard let vm else { return }
        // Re-seed the row before acting on it. `editorViewModel` is created once and reused for every edit
        // session this screen opens, so without this its `scoreItem` is whatever it was at `init` (or its own
        // last save) — stale the moment a revert lands through the score-info sheet, which writes through the
        // Reader's or the Library's OWN copy of the row, never this one. A stale `scoreItem` still names a
        // sidecar the store has already deleted, so the next autosave's capture step sees "already captured"
        // and skips it, silently overwriting the just-restored original with no backup (Critical 1 review fix).
        // `repository` is the same live instance passed into `readerBuilder`'s `ReaderRootScreen`, so its
        // observed cache already carries whatever was last written by the time the user gets back into edit
        // mode. This also fixes the milder pre-existing bug where a title edited in the sheet was clobbered by
        // this view model's next save.
        if let freshRow = repository.scoreItems.first(where: { $0.id == vm.scoreItemID }) {
            vm.refreshRow(freshRow)
        }
        vm.beginSession(score: score)
        // Carry the reader's last tap into the session: the note under the playhead is almost always the one the
        // user came here to change.
        vm.selectItem(host?.pendingSelection)
    }
    host.onEndEditing = { [weak vm] in
        guard let vm else { return }
        Task { await vm.endSession() }
    }
    host.onTap = { [weak vm] point in
        guard let vm else { return }
        vm.handleTap(at: point)
    }
    host.onTapOutsideScore = { [weak vm] in
        vm?.deselect()
    }
    // The other half of a completed revert: the Editor rewrote the file and the row, but has no way to make the
    // Reader — which is still drawing the edited score it already had in memory — notice.
    vm.onRevertCompleted = { [weak host] item in
        host?.requestReloadAfterRevert(item)
    }
    wirePartEditSeams(host: host, viewModel: vm, analytics: analytics)
    // Straight from the Reader's overlay into the view model, with no SwiftUI body in between: this fires on every
    // scroll and zoom frame, and anything that read it in a body would re-render the score at that rate.
    host.onSelectionAnchorChanged = { [weak vm] anchor in
        vm?.selectionAnchor = anchor
    }
    vm.documentProvider = { [weak host] in
        guard let host else { return nil }
        return host.document
    }
    // The document above is laid out from whatever the Reader is SHOWING, which drops the staves the reader has
    // hidden and renumbers the rest; the view model edits (and saves) the score entire. The host owns that
    // conversion because only the Reader knows the current visibility.
    vm.displayToSourceItem = { [weak host] item in
        guard let host else { return item }
        return host.sourceItem(for: item)
    }
    // The instruments sheet lists the score's parts (the Editor's business) with a visibility switch per staff
    // (the Reader's). Both halves land in one list, so the two seams meet here — the same place the addressing
    // conversion above does, and for the same reason: neither feature can see the other.
    vm.isStaffVisible = { [weak host] address in
        host?.isStaffVisible(address) ?? true
    }
    vm.onToggleStaffVisibility = { [weak host] address in
        host?.onToggleStaffVisibility(address)
    }
    vm.onScoreChanged = { [weak host] score in
        guard let host else { return }
        host.editedScore = score
        host.editGeneration += 1
    }
    // Two markers, not one: `selection` tints the item the editing keys act on, `caret` draws the insertion bar
    // where the next note lands. They coincide until a run of input pulls the caret ahead of the selection.
    vm.onSelectionChanged = { [weak host] selection, caret in
        guard let host else { return }
        host.selection = selection
        host.caretItem = caret
    }
}

/// The part add / remove / reorder half of the seam, split out of
/// `wireEditingSeam(host:viewModel:repository:analytics:)` to keep it inside SwiftLint's `function_body_length`
/// budget.
///
/// The Editor migrates the persisted `ReaderPreferences` row onto the new part numbering, but the Reader is
/// holding the very same state in memory — and that copy is what its next preference write would persist. Two
/// seams, because the window between the edit and the migration is one the Reader must not write in at all, not
/// merely one it has to re-read after: a write stamped in the new numbering that beats the migration is remapped
/// a second time onto a different part, and one stamped in the old numbering that follows it overwrites the
/// migrated row after the map has been consumed, so nothing ever retries.
/// The hold is raised from the Editor and released by the Reader, deliberately asymmetrically: the Editor knows
/// when the row stops being trustworthy, but only the Reader knows when its own in-memory copy has caught up.
/// `isPartMappingSettled` is how the release asks the Editor whether a LATER part edit has since raised it again.
@MainActor
private func wirePartEditSeams(host: ReaderEditingHost, viewModel vm: EditorViewModel, analytics: any Analytics) {
    vm.onPartEditApplied = { [weak host] in
        host?.raisePartMappingHold()
    }
    // Between the hold going up and the migration reading: the Reader lands whatever its own writers still have in
    // the air. The annotation layer needs it — its saves are debounced, so one registered just before the part
    // edit would otherwise land on the far side of the migration and put the ink back into the old numbering.
    vm.onPartMigrationWillRun = { [weak host] in
        await host?.prepareForPartMigration()
    }
    // The Editor's own count of what the user changed about the instrumentation. Logged here rather than there:
    // the Editor has no analytics client, and this is the composition root that owns the one there is.
    vm.onPartsEdited = { [analytics] action in
        analytics.log(.scorePartsEdited(action: action.rawValue))
    }
    // Same seam, same reason, for the key and time signature sheets.
    vm.onSignatureChanged = { [analytics] kind, action in
        analytics.log(.scoreSignatureChanged(kind: kind, action: action))
    }
    // Same seam, same reason, for the rehearsal-mark sheet.
    vm.onRehearsalMarkEdited = { [analytics] action in
        analytics.log(.scoreRehearsalMarkEdited(action: action))
    }
    host.isPartMappingSettled = { [weak vm] in
        vm?.hasUnsettledPartEdits != true
    }
    vm.onPartIndicesRemapped = { [weak host] _ in
        host?.requestReloadAfterPartRemap()
    }
}
