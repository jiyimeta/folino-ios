package com.keynumber.folino.ui.library

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.PlaylistAdd
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.IosShare
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.automirrored.outlined.Label
import androidx.compose.material.icons.outlined.RadioButtonUnchecked
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.SnackbarResult
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.keynumber.folino.R
import com.keynumber.folino.library.ScoreRowWire
import com.keynumber.folino.library.generated.LibraryAndroidStoreViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LibraryScreen(
    viewModel: LibraryAndroidStoreViewModel,
    onOpenScore: (ScoreRowWire) -> Unit,
    onOpenDrawer: () -> Unit,
) {
    val scores by viewModel.scores.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val snackbarHost = remember { SnackbarHostState() }
    val scope = rememberCoroutineScope()

    var selectionMode by remember { mutableStateOf(false) }
    val selectedIds = remember { mutableStateListOf<String>() }
    var singleAddTarget by remember { mutableStateOf<String?>(null) }
    var showBulkAddSheet by remember { mutableStateOf(false) }
    var singleTagTarget by remember { mutableStateOf<String?>(null) }
    var showBulkTagSheet by remember { mutableStateOf(false) }

    var exportFormats by remember {
        mutableStateOf<List<com.keynumber.folino.library.ScoreExportFormatWire>>(emptyList())
    }
    var exportTargets by remember { mutableStateOf<List<String>>(emptyList()) }
    var showExportSheet by remember { mutableStateOf(false) }
    var exporting by remember { mutableStateOf(false) }
    val exportFailedMsg = stringResource(R.string.export_failed)

    fun exitSelection() {
        selectionMode = false
        selectedIds.clear()
    }

    fun toggle(id: String) {
        if (selectedIds.contains(id)) selectedIds.remove(id) else selectedIds.add(id)
        if (selectedIds.isEmpty()) selectionMode = false
    }

    fun beginExport(ids: List<String>) {
        if (ids.isEmpty()) return
        exportTargets = ids
        // Formats are identical across scores, so probe the first one.
        exportFormats = viewModel.exportFormats(ids.first())
        showExportSheet = true
    }

    fun runExport(token: String) {
        showExportSheet = false
        val ids = exportTargets
        scope.launch {
            exporting = true
            val dir = com.keynumber.folino.export.ScoreShareLauncher.exportsDir(context).absolutePath
            // exportScore does heavy work and (for PDF/audio) calls back into Kotlin via
            // runBlocking, so it must never run on the main thread.
            val paths = withContext(Dispatchers.Default) {
                ids.map { viewModel.exportScore(it, token, dir) }
            }
            exporting = false
            if (paths.any { it.isEmpty() }) {
                snackbarHost.showSnackbar(exportFailedMsg)
                return@launch
            }
            com.keynumber.folino.export.ScoreShareLauncher.share(context, paths)
        }
    }

    val picker = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocument(),
    ) { uri ->
        if (uri != null) {
            val displayName = originalDisplayName(context, uri)
            val cacheFile = java.io.File(context.cacheDir, displayName)
            context.contentResolver.openInputStream(uri)?.use { input ->
                cacheFile.outputStream().use { output -> input.copyTo(output) }
            }
            viewModel.importScore(cacheFile.absolutePath)
        }
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
                            onClick = { beginExport(selectedIds.toList()) },
                        ) {
                            Icon(
                                Icons.Filled.IosShare,
                                contentDescription = stringResource(R.string.export),
                            )
                        }
                        IconButton(
                            enabled = selectedIds.isNotEmpty(),
                            onClick = {
                                viewModel.beginBulkAddToPlaylist()
                                showBulkAddSheet = true
                            },
                        ) {
                            Icon(
                                Icons.AutoMirrored.Filled.PlaylistAdd,
                                contentDescription = stringResource(R.string.add_to_playlist),
                            )
                        }
                        IconButton(
                            enabled = selectedIds.isNotEmpty(),
                            onClick = {
                                viewModel.beginBulkEditTags()
                                showBulkTagSheet = true
                            },
                        ) {
                            Icon(
                                Icons.AutoMirrored.Outlined.Label,
                                contentDescription = stringResource(R.string.tag_add),
                            )
                        }
                        IconButton(
                            enabled = selectedIds.isNotEmpty(),
                            onClick = {
                                viewModel.deleteMany(selectedIds.toList())
                                exitSelection()
                            },
                        ) {
                            Icon(Icons.Filled.Delete, contentDescription = stringResource(R.string.library_delete))
                        }
                    },
                )
            } else {
                TopAppBar(
                    title = { Text(stringResource(R.string.library_title)) },
                    navigationIcon = {
                        IconButton(onClick = onOpenDrawer) {
                            Icon(Icons.Filled.Menu, contentDescription = stringResource(R.string.nav_open_menu))
                        }
                    },
                )
            }
        },
        snackbarHost = { SnackbarHost(snackbarHost) },
        floatingActionButton = {
            if (!selectionMode) {
                FloatingActionButton(onClick = { picker.launch(arrayOf("*/*")) }) {
                    Icon(Icons.Filled.Add, contentDescription = stringResource(R.string.library_import))
                }
            }
        },
    ) { padding ->
        if (scores.isEmpty()) {
            EmptyState(
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
                items(scores, key = { it.id }) { row ->
                    ScoreRow(
                        row = row,
                        selectionMode = selectionMode,
                        selected = selectedIds.contains(row.id),
                        onClick = { if (selectionMode) toggle(row.id) else onOpenScore(row) },
                        onLongClick = {
                            if (!selectionMode) selectionMode = true
                            toggle(row.id)
                        },
                        onDelete = {
                            viewModel.delete(row.id)
                            scope.launch {
                                val result = snackbarHost.showSnackbar(
                                    message = context.getString(R.string.library_deleted),
                                    actionLabel = context.getString(R.string.library_undo),
                                )
                                if (result == SnackbarResult.ActionPerformed) viewModel.restore(row.id)
                            }
                        },
                        onAddToPlaylist = {
                            singleAddTarget = row.id
                            viewModel.beginAddToPlaylist(row.id)
                        },
                        onEditTags = {
                            singleTagTarget = row.id
                            viewModel.beginEditTags(row.id)
                        },
                        onExport = { beginExport(listOf(row.id)) },
                    )
                }
            }
        }
    }

    singleAddTarget?.let { id ->
        AddToPlaylistSheet(
            viewModel = viewModel,
            scoreId = id,
            bulkScoreIds = emptyList(),
            onDismiss = { singleAddTarget = null },
        )
    }
    if (showBulkAddSheet) {
        AddToPlaylistSheet(
            viewModel = viewModel,
            scoreId = null,
            bulkScoreIds = selectedIds.toList(),
            onDismiss = {
                showBulkAddSheet = false
                exitSelection()
            },
        )
    }
    singleTagTarget?.let { id ->
        EditTagsSheet(
            viewModel = viewModel,
            scoreId = id,
            bulkScoreIds = emptyList(),
            onDismiss = { singleTagTarget = null },
        )
    }
    if (showBulkTagSheet) {
        EditTagsSheet(
            viewModel = viewModel,
            scoreId = null,
            bulkScoreIds = selectedIds.toList(),
            onDismiss = {
                showBulkTagSheet = false
                exitSelection()
            },
        )
    }
    if (showExportSheet) {
        ExportFormatSheet(
            formats = exportFormats,
            onPick = { runExport(it) },
            onDismiss = { showExportSheet = false },
        )
    }
    if (exporting) {
        Box(
            Modifier
                .fillMaxSize()
                .background(MaterialTheme.colorScheme.scrim.copy(alpha = 0.32f)),
            contentAlignment = Alignment.Center,
        ) {
            CircularProgressIndicator()
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
private fun ScoreRow(
    row: ScoreRowWire,
    selectionMode: Boolean,
    selected: Boolean,
    onClick: () -> Unit,
    onLongClick: () -> Unit,
    onDelete: () -> Unit,
    onAddToPlaylist: () -> Unit,
    onEditTags: () -> Unit,
    onExport: () -> Unit,
) {
    val content: @Composable () -> Unit = {
        var menu by remember { mutableStateOf(false) }
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
                        IconButton(onClick = { menu = true }) {
                            Icon(Icons.Filled.MoreVert, contentDescription = stringResource(R.string.more))
                        }
                        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                            DropdownMenuItem(
                                text = { Text(stringResource(R.string.export)) },
                                onClick = {
                                    menu = false
                                    onExport()
                                },
                            )
                            DropdownMenuItem(
                                text = { Text(stringResource(R.string.add_to_playlist)) },
                                onClick = {
                                    menu = false
                                    onAddToPlaylist()
                                },
                            )
                            DropdownMenuItem(
                                text = { Text(stringResource(R.string.edit_tags)) },
                                onClick = {
                                    menu = false
                                    onEditTags()
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
        val dismissState = rememberSwipeToDismissBoxState(
            confirmValueChange = {
                if (it == SwipeToDismissBoxValue.EndToStart) {
                    onDelete()
                    true
                } else {
                    false
                }
            },
        )
        SwipeToDismissBox(
            state = dismissState,
            enableDismissFromStartToEnd = false,
            backgroundContent = {
                Box(
                    Modifier
                        .fillMaxSize()
                        .padding(horizontal = 16.dp),
                    contentAlignment = Alignment.CenterEnd,
                ) {
                    Icon(Icons.Filled.Delete, contentDescription = null)
                }
            },
        ) { content() }
    }
}

@Composable
private fun EmptyState(modifier: Modifier) {
    Box(modifier, contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text(stringResource(R.string.library_empty_title), style = MaterialTheme.typography.titleMedium)
            Text(stringResource(R.string.library_empty_hint), style = MaterialTheme.typography.bodyMedium)
        }
    }
}

/// The picked document's original display name (e.g. "Now_is_the_time.mscz"),
/// used to name the cache file so the Swift side derives the title from it.
private fun originalDisplayName(context: android.content.Context, uri: android.net.Uri): String {
    var name: String? = null
    context.contentResolver.query(
        uri, arrayOf(android.provider.OpenableColumns.DISPLAY_NAME), null, null, null,
    )?.use { cursor ->
        if (cursor.moveToFirst()) {
            val idx = cursor.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
            if (idx >= 0) name = cursor.getString(idx)
        }
    }
    return (name ?: "score.mscz").replace('/', '_')
}
