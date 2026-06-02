package com.keynumber.folino.ui.library

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.DeleteForever
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.filled.Restore
import androidx.compose.material.icons.outlined.RadioButtonUnchecked
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.keynumber.folino.R
import com.keynumber.folino.library.ScoreRowWire
import com.keynumber.folino.library.generated.LibraryAndroidStoreViewModel

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RecentlyDeletedScreen(
    viewModel: LibraryAndroidStoreViewModel,
    onOpenScore: (ScoreRowWire) -> Unit,
    onOpenDrawer: () -> Unit,
) {
    val deleted by viewModel.deletedScores.collectAsStateWithLifecycle()
    var selectionMode by remember { mutableStateOf(false) }
    val selectedIds = remember { mutableStateListOf<String>() }
    var pendingSingleDelete by remember { mutableStateOf<ScoreRowWire?>(null) }
    var showBulkDeleteDialog by remember { mutableStateOf(false) }

    fun exitSelection() {
        selectionMode = false
        selectedIds.clear()
    }

    fun toggle(id: String) {
        if (selectedIds.contains(id)) selectedIds.remove(id) else selectedIds.add(id)
        if (selectedIds.isEmpty()) selectionMode = false
    }

    Scaffold(
        topBar = {
            if (selectionMode) {
                TopAppBar(
                    title = { Text(selectedIds.size.toString()) },
                    navigationIcon = {
                        IconButton(onClick = { exitSelection() }) {
                            Icon(Icons.Filled.Close, contentDescription = stringResource(R.string.cancel))
                        }
                    },
                    actions = {
                        IconButton(
                            enabled = selectedIds.isNotEmpty(),
                            onClick = {
                                viewModel.restoreMany(selectedIds.toList())
                                exitSelection()
                            },
                        ) {
                            Icon(
                                Icons.Filled.Restore,
                                contentDescription = stringResource(R.string.recently_deleted_restore),
                            )
                        }
                        IconButton(
                            enabled = selectedIds.isNotEmpty(),
                            onClick = { showBulkDeleteDialog = true },
                        ) {
                            Icon(
                                Icons.Filled.DeleteForever,
                                contentDescription = stringResource(R.string.recently_deleted_delete),
                            )
                        }
                    },
                )
            } else {
                TopAppBar(
                    title = { Text(stringResource(R.string.recently_deleted_title)) },
                    navigationIcon = {
                        IconButton(onClick = onOpenDrawer) {
                            Icon(Icons.Filled.Menu, contentDescription = stringResource(R.string.nav_open_menu))
                        }
                    },
                )
            }
        },
    ) { padding ->
        if (deleted.isEmpty()) {
            EmptyTrash(
                Modifier
                    .padding(padding)
                    .fillMaxSize(),
            )
        } else {
            LazyColumn(
                Modifier
                    .padding(padding)
                    .fillMaxSize(),
            ) {
                items(deleted, key = { it.id }) { row ->
                    TrashRow(
                        row = row,
                        selectionMode = selectionMode,
                        selected = selectedIds.contains(row.id),
                        onClick = { if (selectionMode) toggle(row.id) else onOpenScore(row) },
                        onLongClick = {
                            if (!selectionMode) selectionMode = true
                            toggle(row.id)
                        },
                        onRestore = { viewModel.restore(row.id) },
                        onRequestPermanentDelete = { pendingSingleDelete = row },
                    )
                }
            }
        }
    }

    pendingSingleDelete?.let { row ->
        PermanentDeleteDialog(
            title = stringResource(
                R.string.recently_deleted_delete_confirm_title,
                row.title.ifEmpty { "Untitled" },
            ),
            onConfirm = {
                viewModel.permanentlyDelete(row.id)
                pendingSingleDelete = null
            },
            onDismiss = { pendingSingleDelete = null },
        )
    }

    if (showBulkDeleteDialog) {
        PermanentDeleteDialog(
            title = stringResource(R.string.recently_deleted_delete_bulk_confirm_title, selectedIds.size),
            onConfirm = {
                viewModel.permanentlyDeleteMany(selectedIds.toList())
                showBulkDeleteDialog = false
                exitSelection()
            },
            onDismiss = { showBulkDeleteDialog = false },
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
private fun TrashRow(
    row: ScoreRowWire,
    selectionMode: Boolean,
    selected: Boolean,
    onClick: () -> Unit,
    onLongClick: () -> Unit,
    onRestore: () -> Unit,
    onRequestPermanentDelete: () -> Unit,
) {
    val content: @Composable () -> Unit = {
        var menuExpanded by remember { mutableStateOf(false) }
        val title = row.title.ifEmpty { "Untitled" }
        val headline = if (row.subtitle.isEmpty()) title else "$title ${row.subtitle}"
        ListItem(
            headlineContent = { Text(headline) },
            supportingContent = { if (row.composer.isNotEmpty()) Text(row.composer) },
            leadingContent = {
                if (selectionMode) {
                    Icon(
                        if (selected) Icons.Filled.CheckCircle else Icons.Outlined.RadioButtonUnchecked,
                        contentDescription = null,
                    )
                } else {
                    Icon(Icons.Filled.MusicNote, contentDescription = null)
                }
            },
            trailingContent = {
                if (!selectionMode) {
                    Box {
                        IconButton(onClick = { menuExpanded = true }) {
                            Icon(Icons.Filled.MoreVert, contentDescription = stringResource(R.string.more))
                        }
                        DropdownMenu(expanded = menuExpanded, onDismissRequest = { menuExpanded = false }) {
                            DropdownMenuItem(
                                text = { Text(stringResource(R.string.recently_deleted_restore)) },
                                onClick = {
                                    menuExpanded = false
                                    onRestore()
                                },
                            )
                            DropdownMenuItem(
                                text = { Text(stringResource(R.string.recently_deleted_delete)) },
                                onClick = {
                                    menuExpanded = false
                                    onRequestPermanentDelete()
                                },
                            )
                        }
                    }
                }
            },
            colors = if (selected) {
                ListItemDefaults.colors(containerColor = MaterialTheme.colorScheme.secondaryContainer)
            } else {
                ListItemDefaults.colors()
            },
            modifier = Modifier.combinedClickable(onClick = onClick, onLongClick = onLongClick),
        )
    }

    if (selectionMode) {
        content()
    } else {
        // Leading swipe (start->end) = Restore — a safe, reversible action, so a
        // swipe is appropriate. Permanent delete is irreversible and is NOT bound
        // to a swipe; it goes through the row menu + confirm dialog.
        val dismissState = rememberSwipeToDismissBoxState(
            confirmValueChange = {
                if (it == SwipeToDismissBoxValue.StartToEnd) {
                    onRestore()
                    true
                } else {
                    false
                }
            },
        )
        SwipeToDismissBox(
            state = dismissState,
            enableDismissFromStartToEnd = true,
            enableDismissFromEndToStart = false,
            backgroundContent = {
                Box(
                    Modifier
                        .fillMaxSize()
                        .padding(horizontal = 16.dp),
                    contentAlignment = Alignment.CenterStart,
                ) {
                    Icon(Icons.Filled.Restore, contentDescription = null)
                }
            },
        ) { content() }
    }
}

@Composable
private fun PermanentDeleteDialog(title: String, onConfirm: () -> Unit, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = { Text(stringResource(R.string.recently_deleted_delete_confirm_message)) },
        confirmButton = {
            TextButton(onClick = onConfirm) { Text(stringResource(R.string.recently_deleted_delete)) }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) }
        },
    )
}

@Composable
private fun EmptyTrash(modifier: Modifier) {
    Box(modifier, contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text(stringResource(R.string.recently_deleted_empty_title), style = MaterialTheme.typography.titleMedium)
            Text(stringResource(R.string.recently_deleted_empty_hint), style = MaterialTheme.typography.bodyMedium)
        }
    }
}
