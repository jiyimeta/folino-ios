package com.keynumber.folino.ui.library

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
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
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.keynumber.folino.R
import com.keynumber.folino.library.ScoreRowWire
import com.keynumber.folino.library.generated.LibraryAndroidStoreViewModel
import kotlinx.coroutines.launch

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

    val picker = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocument(),
    ) { uri ->
        if (uri != null) {
            // importScore takes a filesystem PATH (String), not bytes — the
            // bridge can't marshal Data args. Copy the picked content:// doc
            // into the app cache dir, naming the cache file with the picked
            // document's ORIGINAL display name so the Swift side derives the
            // library title from it (matching the iOS importer, which uses the
            // file name — not the score's workTitle metaTag).
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
            TopAppBar(
                title = { Text(stringResource(R.string.library_title)) },
                navigationIcon = {
                    IconButton(onClick = onOpenDrawer) {
                        Icon(Icons.Filled.Menu, contentDescription = stringResource(R.string.nav_open_menu))
                    }
                },
            )
        },
        snackbarHost = { SnackbarHost(snackbarHost) },
        floatingActionButton = {
            FloatingActionButton(onClick = {
                // .mscz has no registered MIME on most devices; widen to */* and rely
                // on the parser to reject non-mscz input.
                picker.launch(arrayOf("*/*"))
            }) { Icon(Icons.Filled.Add, contentDescription = stringResource(R.string.library_import)) }
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
                        onClick = { onOpenScore(row) },
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
                    )
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ScoreRow(row: ScoreRowWire, onClick: () -> Unit, onDelete: () -> Unit) {
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
    ) {
        val title = row.title.ifEmpty { "Untitled" }
        // Primary line mirrors the iOS row: "title subtitle".
        val headline = if (row.subtitle.isEmpty()) title else "$title ${row.subtitle}"
        ListItem(
            headlineContent = { Text(headline) },
            supportingContent = { if (row.composer.isNotEmpty()) Text(row.composer) },
            leadingContent = { Icon(Icons.Filled.MusicNote, contentDescription = null) },
            modifier = Modifier.clickable(onClick = onClick),
        )
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
    // Guard against path separators; fall back when the provider gives nothing.
    return (name ?: "score.mscz").replace('/', '_')
}
