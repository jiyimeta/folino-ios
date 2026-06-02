package com.keynumber.folino.ui.library

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.DragHandle
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.keynumber.folino.R
import com.keynumber.folino.library.ScoreRowWire
import com.keynumber.folino.library.generated.LibraryAndroidStoreViewModel
import sh.calvin.reorderable.ReorderableItem
import sh.calvin.reorderable.rememberReorderableLazyListState

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PlaylistDetailScreen(
    viewModel: LibraryAndroidStoreViewModel,
    playlistId: String,
    playlistName: String,
    onOpenScore: (ScoreRowWire) -> Unit,
    onBack: () -> Unit,
) {
    LaunchedEffect(playlistId) { viewModel.selectPlaylist(playlistId) }
    val items by viewModel.selectedPlaylistItems.collectAsStateWithLifecycle()

    // Local mirror so a drag reorders immediately; re-sync when the store emits.
    val local = remember { mutableStateListOf<ScoreRowWire>() }
    LaunchedEffect(items) {
        if (local.map { it.id } != items.map { it.id }) {
            local.clear()
            local.addAll(items)
        }
    }

    var showRename by remember { mutableStateOf(false) }
    var showDelete by remember { mutableStateOf(false) }
    var menu by remember { mutableStateOf(false) }

    val listState = rememberLazyListState()
    val reorderState = rememberReorderableLazyListState(listState) { from, to ->
        local.add(to.index, local.removeAt(from.index))
        viewModel.setPlaylistOrder(playlistId, local.map { it.id })
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(playlistName) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = stringResource(R.string.cancel))
                    }
                },
                actions = {
                    Box {
                        IconButton(onClick = { menu = true }) {
                            Icon(Icons.Filled.MoreVert, contentDescription = stringResource(R.string.more))
                        }
                        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                            DropdownMenuItem(
                                text = { Text(stringResource(R.string.playlists_rename)) },
                                onClick = {
                                    menu = false
                                    showRename = true
                                },
                            )
                            DropdownMenuItem(
                                text = { Text(stringResource(R.string.playlists_delete)) },
                                onClick = {
                                    menu = false
                                    showDelete = true
                                },
                            )
                        }
                    }
                },
            )
        },
    ) { padding ->
        if (local.isEmpty()) {
            Box(
                Modifier
                    .padding(padding)
                    .fillMaxSize(),
                contentAlignment = Alignment.Center,
            ) {
                Text(stringResource(R.string.playlists_empty_hint), style = MaterialTheme.typography.bodyMedium)
            }
        } else {
            LazyColumn(
                state = listState,
                modifier = Modifier
                    .padding(padding)
                    .fillMaxSize(),
            ) {
                items(local, key = { it.id }) { row ->
                    ReorderableItem(reorderState, key = row.id) {
                        var rowMenu by remember { mutableStateOf(false) }
                        val title = row.title.ifEmpty { "Untitled" }
                        val headline = if (row.subtitle.isEmpty()) title else "$title ${row.subtitle}"
                        ListItem(
                            headlineContent = { Text(headline) },
                            supportingContent = { if (row.composer.isNotEmpty()) Text(row.composer) },
                            leadingContent = {
                                IconButton(modifier = Modifier.draggableHandle(), onClick = {}) {
                                    Icon(
                                        Icons.Filled.DragHandle,
                                        contentDescription = stringResource(R.string.playlist_reorder_handle),
                                    )
                                }
                            },
                            trailingContent = {
                                Box {
                                    IconButton(onClick = { rowMenu = true }) {
                                        Icon(Icons.Filled.MoreVert, contentDescription = stringResource(R.string.more))
                                    }
                                    DropdownMenu(expanded = rowMenu, onDismissRequest = { rowMenu = false }) {
                                        DropdownMenuItem(
                                            text = { Text(stringResource(R.string.playlist_remove_from)) },
                                            onClick = {
                                                rowMenu = false
                                                viewModel.removeFromPlaylist(row.id, playlistId)
                                            },
                                        )
                                    }
                                }
                            },
                            modifier = Modifier.clickable { onOpenScore(row) },
                        )
                    }
                }
            }
        }
    }

    if (showRename) {
        NameDialog(
            title = stringResource(R.string.playlists_rename),
            confirmLabel = stringResource(R.string.rename),
            initial = playlistName,
            onConfirm = { name ->
                viewModel.renamePlaylist(playlistId, name)
                showRename = false
            },
            onDismiss = { showRename = false },
        )
    }
    if (showDelete) {
        AlertDialog(
            onDismissRequest = { showDelete = false },
            title = { Text(stringResource(R.string.playlists_delete_confirm_title, playlistName)) },
            text = { Text(stringResource(R.string.playlists_delete_confirm_message)) },
            confirmButton = {
                TextButton(onClick = {
                    viewModel.deletePlaylist(playlistId)
                    showDelete = false
                    onBack()
                }) {
                    Text(stringResource(R.string.playlists_delete))
                }
            },
            dismissButton = { TextButton(onClick = { showDelete = false }) { Text(stringResource(R.string.cancel)) } },
        )
    }
}
